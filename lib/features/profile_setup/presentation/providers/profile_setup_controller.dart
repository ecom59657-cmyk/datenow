import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/age.dart';
import '../../../../core/utils/logger.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../profile_moderation/data/photo_moderation_repository.dart';
import '../../data/profile_repository.dart';
import '../../domain/enums.dart';
import '../../domain/interest.dart';
import '../../domain/prompt.dart';
import '../../domain/prompt_answer.dart';
import '../../domain/user_profile.dart';

/// Working copy of the profile being built across the multi-step flow.
///
/// Lives separate from the persisted [UserProfile] so we can mutate freely
/// (toggle chips, drag sliders) without round-tripping through the repo on
/// every keystroke. Persisted in one shot at the end via [submit].
class ProfileSetupController extends StateNotifier<ProfileDraft> {
  ProfileSetupController(this._ref)
      : super(ProfileDraft.initial(
          userId: _ref.read(currentUserProvider)?.id ?? '',
          initialName: _ref.read(currentUserProvider)?.displayName,
          initialBirthDate: _ref.read(currentUserProvider)?.birthDate,
        ));

  final Ref _ref;

  // ---------- Step 1 ----------
  void setFirstName(String value) => state = state.copyWith(firstName: value);
  void setGender(Gender value) => state = state.copyWith(gender: value);
  void setOrientation(Orientation value) =>
      state = state.copyWith(orientation: value);

  /// Sets birth date for users who arrived via OAuth (Apple/Google) —
  /// these flows never provide DOB, so the picker on step 1 is the
  /// only entry point. Email/OTP users land here with a non-null DOB
  /// already (collected at signup) and the UI hides the picker in
  /// favour of a locked summary card.
  void setBirthDate(DateTime value) =>
      state = state.copyWith(birthDate: value);

  // ---------- Step 2 ----------
  void toggleSeekingGender(Gender g) {
    final next = {...state.seekingGenders};
    next.contains(g) ? next.remove(g) : next.add(g);
    state = state.copyWith(seekingGenders: next);
  }

  void setAgeRange(int min, int max) =>
      state = state.copyWith(seekingAgeMin: min, seekingAgeMax: max);

  void setMaxDistance(int km) => state = state.copyWith(maxDistanceKm: km);

  /// Writes one answer. An empty string removes it, so clearing a field is
  /// how you drop a prompt — no separate delete affordance to discover.
  void setPrompt(PromptQuestion question, String answer) {
    final next = [...state.prompts.where((p) => p.question != question)];
    if (answer.trim().isNotEmpty) {
      next.add(PromptAnswer(
        question: question,
        answer: answer.trim(),
        position: next.length,
      ));
    }
    for (var i = 0; i < next.length; i++) {
      next[i] = next[i].copyWith(position: i);
    }
    state = state.copyWith(prompts: next);
  }

  // ---------- Step 3 ----------
  void toggleIntention(Intention i) {
    final next = {...state.intentions};
    next.contains(i) ? next.remove(i) : next.add(i);
    state = state.copyWith(intentions: next);
  }

  void toggleInterest(Interest i) {
    final next = {...state.interests};
    next.contains(i) ? next.remove(i) : next.add(i);
    state = state.copyWith(interests: next);
  }

  // ---------- Step 4 ----------
  void setAvailability(Availability a) =>
      state = state.copyWith(availability: a);

  void setPhotoBytes(Uint8List? bytes) =>
      state = state.copyWith(photoBytes: bytes);

  // ---------- Submission ----------

  static const _log = AppLogger('ProfileSetup');
  static const _saveTimeout = Duration(seconds: 20);

  /// Validates and persists the draft.
  ///
  /// Returns `true` when the profile was saved end-to-end; `false` only when
  /// the draft fails the in-memory validation. Real errors (network /
  /// Supabase / RLS) **throw** so the calling screen can surface a clear
  /// message instead of silently dropping back to a loading state.
  ///
  /// The whole save is wrapped in a [_saveTimeout] guard so the UI is never
  /// stuck on a hanging request — the user gets an explicit timeout error
  /// instead of an infinite spinner.
  Future<bool> submit() async {
    if (!state.isComplete) {
      _log.warn('submit refused — draft is not complete');
      return false;
    }

    _log.info('Save started for user ${state.userId}');
    final repo = _ref.read(profileRepositoryProvider);

    final photoUrls = <String>[];
    if (state.photoBytes != null) {
      _log.info('Uploading profile photo (${state.photoBytes!.length} bytes)');
      try {
        photoUrls.add(
          await repo
              .uploadPhoto(state.userId, state.photoBytes!)
              .timeout(_saveTimeout),
        );
        // ── Photo moderation hook ────────────────────────────────
        // Onboarding MUST use the exact same pipeline as
        // `edit_photos_screen` — otherwise the newly inserted
        // user_photos row would stay `status='pending'` forever and
        // the find-date gate would refuse the user indefinitely.
        // Fire-and-forget : the user proceeds with onboarding while
        // analyze-profile-photo (Google Vision) decides; the gate
        // will see the verdict the next time it asks
        // `has_approved_photo()`. Failures inside the moderation
        // repo are swallowed by the repo (falls back to a `pending`
        // verdict) — so we never block onboarding completion on a
        // Vision-side hiccup.
        final moderation = _ref.read(photoModerationRepositoryProvider);
        if (moderation != null) {
          unawaited(moderation.analyzeByStoragePath(photoUrls.last));
        }
      } catch (e, st) {
        // Photo failures are surfaced but non-fatal: the user can still
        // complete onboarding without a picture (it's optional anyway) so
        // we log + continue with no photo.
        _log.warn('Photo upload failed: $e — continuing without photo');
        _log.error('photo upload stack', e, st);
      }
    }

    final profile = UserProfile(
      userId: state.userId,
      firstName: state.firstName?.trim(),
      birthDate: state.birthDate,
      gender: state.gender,
      orientation: state.orientation,
      seekingGenders: state.seekingGenders,
      seekingAgeMin: state.seekingAgeMin,
      seekingAgeMax: state.seekingAgeMax,
      maxDistanceKm: state.maxDistanceKm,
      intentions: state.intentions,
      interests: state.interests,
      availability: state.availability,
      prompts: state.filledPrompts,
      photoUrls: photoUrls,
    );

    try {
      await repo.saveProfile(profile).timeout(_saveTimeout);
      _log.info('Save succeeded for user ${state.userId}');
      return true;
    } on TimeoutException {
      _log.error('Save timed out after ${_saveTimeout.inSeconds}s');
      throw const _SaveTimeoutFailure();
    } catch (e, st) {
      _log.error('Save error: $e', e, st);
      rethrow;
    }
  }
}

class _SaveTimeoutFailure implements Exception {
  const _SaveTimeoutFailure();
  @override
  String toString() => 'Save timed out';
}

/// Plain value object — mirrors [UserProfile] but allows nullable fields
/// during the in-progress flow plus a transient [photoBytes] buffer (only
/// useful before upload).
class ProfileDraft {
  ProfileDraft({
    required this.userId,
    this.firstName,
    this.birthDate,
    this.gender,
    this.orientation,
    this.seekingGenders = const <Gender>{},
    this.seekingAgeMin = 18,
    this.seekingAgeMax = 40,
    this.maxDistanceKm = 50,
    this.intentions = const <Intention>{},
    this.interests = const <Interest>{},
    this.availability,
    this.prompts = const <PromptAnswer>[],
    this.photoBytes,
  });

  factory ProfileDraft.initial({
    required String userId,
    String? initialName,
    DateTime? initialBirthDate,
  }) {
    return ProfileDraft(
      userId: userId,
      firstName: initialName,
      birthDate: initialBirthDate,
    );
  }

  final String userId;
  final String? firstName;
  final DateTime? birthDate;
  final Gender? gender;
  final Orientation? orientation;
  final Set<Gender> seekingGenders;
  final int seekingAgeMin;
  final int seekingAgeMax;
  final int maxDistanceKm;
  final Set<Intention> intentions;
  final Set<Interest> interests;
  final Availability? availability;
  final List<PromptAnswer> prompts;
  final Uint8List? photoBytes;

  int? get age =>
      birthDate == null ? null : ageFromBirthDate(birthDate!);

  bool get isStep1Valid =>
      (firstName?.trim().isNotEmpty ?? false) &&
      birthDate != null &&
      isOfMinimumAge(birthDate!) &&
      gender != null &&
      orientation != null;

  bool get isStep2Valid => seekingGenders.isNotEmpty;

  bool get isStep3Valid => intentions.isNotEmpty && interests.length >= 3;

  bool get isStep4Valid => availability != null;

  /// Answers actually written, blanks dropped.
  List<PromptAnswer> get filledPrompts =>
      prompts.where((p) => p.isFilled).toList(growable: false);

  /// Two answers, per [PromptRules.minAnswered]. Required inside the
  /// wizard, but deliberately NOT part of [UserProfile.isComplete] — see
  /// the note on the step for why.
  bool get isStep5Valid => filledPrompts.length >= PromptRules.minAnswered;

  bool get isComplete =>
      isStep1Valid && isStep2Valid && isStep3Valid && isStep4Valid;

  ProfileDraft copyWith({
    String? firstName,
    DateTime? birthDate,
    Gender? gender,
    Orientation? orientation,
    Set<Gender>? seekingGenders,
    int? seekingAgeMin,
    int? seekingAgeMax,
    int? maxDistanceKm,
    Set<Intention>? intentions,
    Set<Interest>? interests,
    Availability? availability,
    List<PromptAnswer>? prompts,
    Object? photoBytes = _unset,
  }) {
    return ProfileDraft(
      userId: userId,
      firstName: firstName ?? this.firstName,
      birthDate: birthDate ?? this.birthDate,
      gender: gender ?? this.gender,
      orientation: orientation ?? this.orientation,
      seekingGenders: seekingGenders ?? this.seekingGenders,
      seekingAgeMin: seekingAgeMin ?? this.seekingAgeMin,
      seekingAgeMax: seekingAgeMax ?? this.seekingAgeMax,
      maxDistanceKm: maxDistanceKm ?? this.maxDistanceKm,
      intentions: intentions ?? this.intentions,
      interests: interests ?? this.interests,
      availability: availability ?? this.availability,
      prompts: prompts ?? this.prompts,
      photoBytes: identical(photoBytes, _unset)
          ? this.photoBytes
          : photoBytes as Uint8List?,
    );
  }

  static const _unset = Object();
}

final profileSetupControllerProvider =
    StateNotifierProvider<ProfileSetupController, ProfileDraft>(
  ProfileSetupController.new,
);
