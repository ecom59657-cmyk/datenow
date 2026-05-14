import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../domain/enums.dart';
import '../domain/interest.dart';
import '../domain/user_profile.dart';

/// Abstract profile store. Concrete impls plug in Supabase or an in-memory
/// mock — the rest of the app only ever depends on this surface.
abstract class ProfileRepository {
  /// Continuously emits the latest [UserProfile] for [userId] (or `null` if
  /// none exists yet). Used by the router redirect.
  Stream<UserProfile?> watchProfile(String userId);

  /// Best-effort one-shot fetch.
  Future<UserProfile?> getProfile(String userId);

  /// Persists the profile. Implementations should emit the new value on the
  /// matching `watchProfile` stream so reactive consumers refresh.
  Future<void> saveProfile(UserProfile profile);

  /// Uploads a photo and returns an opaque identifier ("URL"). Storage and
  /// privacy enforcement is the caller's responsibility — the photo must
  /// never be displayed outside the post-call reveal screen.
  Future<String> uploadPhoto(String userId, Uint8List bytes);

  /// Releases storage for [url] returned by [uploadPhoto]. Safe to call on
  /// an unknown URL — no-op in that case. Callers are also responsible for
  /// removing the URL from the profile's `photoUrls` list.
  Future<void> deletePhoto(String url);

  /// Resolves the raw bytes for a photo identifier. Returns `null` when the
  /// identifier is unknown.
  Future<Uint8List?> getPhotoBytes(String url);
}

// ---------------------------------------------------------------------------
// Mock implementation — used in dev when Supabase isn't configured
// ---------------------------------------------------------------------------

/// In-memory profile storage. Survives across the session but resets on
/// browser/app restart — exactly what we want for demo mode.
class MockProfileRepository implements ProfileRepository {
  static const _log = AppLogger('MockProfile');

  final Map<String, UserProfile> _byUser = {};
  final Map<String, StreamController<UserProfile?>> _streams = {};
  final Map<String, Uint8List> _photoBytes = {};

  StreamController<UserProfile?> _streamFor(String userId) {
    return _streams.putIfAbsent(
      userId,
      () => StreamController<UserProfile?>.broadcast(),
    );
  }

  @override
  Stream<UserProfile?> watchProfile(String userId) async* {
    yield _byUser[userId];
    yield* _streamFor(userId).stream;
  }

  @override
  Future<UserProfile?> getProfile(String userId) async => _byUser[userId];

  @override
  Future<void> saveProfile(UserProfile profile) async {
    _log.info(
      'save profile for ${profile.userId} (complete=${profile.isComplete})',
    );
    _byUser[profile.userId] = profile;
    _streamFor(profile.userId).add(profile);
  }

  int _photoCounter = 0;

  @override
  Future<String> uploadPhoto(String userId, Uint8List bytes) async {
    // Simulate network latency to make the UI loading state believable.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final url = 'mock://photo/$userId/${_photoCounter++}';
    _photoBytes[url] = bytes;
    return url;
  }

  @override
  Future<void> deletePhoto(String url) async {
    _photoBytes.remove(url);
  }

  @override
  Future<Uint8List?> getPhotoBytes(String url) async => _photoBytes[url];
}

// ---------------------------------------------------------------------------
// Supabase implementation
// ---------------------------------------------------------------------------

/// Reads/writes against the schema defined in `supabase/migrations/`:
///   - `profiles` row (auto-created by `handle_new_user` trigger at signup),
///   - `user_preferences` row,
///   - `user_photos` rows (one per uploaded picture),
///   - `profile-photos` Storage bucket (private, owner-only + matched peers).
///
/// The repository maintains a local cache + a broadcast stream per user so
/// the rest of the app (router redirect, profile screens) reacts the
/// moment a write completes — without waiting on Supabase realtime, which
/// we can layer in later without changing this surface.
class SupabaseProfileRepository implements ProfileRepository {
  SupabaseProfileRepository(this._client);

  final sb.SupabaseClient _client;
  static const _log = AppLogger('SupabaseProfile');
  static const _bucket = 'profile-photos';

  final Map<String, UserProfile> _cache = {};
  final Map<String, StreamController<UserProfile?>> _streams = {};
  bool _bootstrapped = false;

  StreamController<UserProfile?> _streamFor(String userId) =>
      _streams.putIfAbsent(
        userId,
        () => StreamController<UserProfile?>.broadcast(),
      );

  // ---------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------

  @override
  Stream<UserProfile?> watchProfile(String userId) async* {
    // First emission: cache or one-shot fetch. After that, ride the
    // broadcast stream and emit every time a write completes locally.
    if (!_bootstrapped || !_cache.containsKey(userId)) {
      try {
        final fetched = await getProfile(userId);
        _cache[userId] = fetched ?? UserProfile(userId: userId);
        _bootstrapped = true;
      } catch (e, st) {
        _log.error('watchProfile bootstrap failed for $userId', e, st);
        _cache[userId] = UserProfile(userId: userId);
      }
    }
    yield _cache[userId];
    yield* _streamFor(userId).stream;
  }

  @override
  Future<UserProfile?> getProfile(String userId) async {
    final profileRow = await _client
        .from('profiles')
        .select()
        .eq('id', userId)
        .maybeSingle();

    if (profileRow == null) {
      _log.warn(
        'profiles row not found for $userId — has handle_new_user run? '
        '(check that the migrations under supabase/migrations/ are applied)',
      );
      return null;
    }

    final prefsRow = await _client
        .from('user_preferences')
        .select()
        .eq('user_id', userId)
        .maybeSingle();

    final photoRows = await _client
        .from('user_photos')
        .select()
        .eq('user_id', userId)
        .order('position');

    return _mapToProfile(userId, profileRow, prefsRow, photoRows);
  }

  // ---------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------

  @override
  Future<void> saveProfile(UserProfile profile) async {
    _log.info('saveProfile started for ${profile.userId}');

    final birth = profile.birthDate;
    if (birth == null) {
      throw StateError('saveProfile called with null birthDate');
    }

    // 1. Update `profiles` (UPSERT in case the row hasn't been created
    //    yet — RLS allows the user to upsert their own row).
    await _client.from('profiles').upsert({
      'id': profile.userId,
      'first_name': profile.firstName,
      'birth_date': _formatDate(birth),
      if (profile.gender != null) 'gender': _genderToDb(profile.gender!),
      if (profile.orientation != null)
        'sexual_orientation': profile.orientation!.name,
      if (profile.firstName != null) 'display_name': profile.firstName,
    });

    // 2. Upsert `user_preferences`.
    await _client.from('user_preferences').upsert({
      'user_id': profile.userId,
      'seeking_genders':
          profile.seekingGenders.map(_genderToDb).toList(growable: false),
      'seeking_age_min': profile.seekingAgeMin,
      'seeking_age_max': profile.seekingAgeMax,
      'max_distance_km': profile.maxDistanceKm,
      'intentions':
          profile.intentions.map((e) => e.name).toList(growable: false),
      'interests':
          profile.interests.map((e) => e.name).toList(growable: false),
      if (profile.availability != null)
        'availability': profile.availability!.name,
    });

    _log.info('saveProfile DB writes done for ${profile.userId}');

    // 3. Refresh the cache from the source of truth and emit so the
    //    router redirect picks up the new isComplete instantly.
    await _refresh(profile.userId);
  }

  Future<void> _refresh(String userId) async {
    try {
      final fresh = await getProfile(userId);
      if (fresh != null) {
        _cache[userId] = fresh;
        _streamFor(userId).add(fresh);
        _log.info(
          'profile refreshed for $userId (isComplete=${fresh.isComplete})',
        );
      }
    } catch (e, st) {
      _log.error('profile refresh failed for $userId', e, st);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------
  // Photos
  // ---------------------------------------------------------------------

  @override
  Future<String> uploadPhoto(String userId, Uint8List bytes) async {
    final fileName = 'photo-${DateTime.now().millisecondsSinceEpoch}.jpg';
    final path = '$userId/$fileName';

    _log.info('uploadPhoto: storing ${bytes.length} bytes at $path');
    await _client.storage.from(_bucket).uploadBinary(
          path,
          bytes,
          fileOptions: const sb.FileOptions(
            contentType: 'image/jpeg',
            upsert: false,
          ),
        );

    // Compute the next position for this user's photo list.
    final existing = await _client
        .from('user_photos')
        .select('position')
        .eq('user_id', userId)
        .order('position', ascending: false)
        .limit(1)
        .maybeSingle();
    final nextPosition =
        existing == null ? 0 : (existing['position'] as int) + 1;

    await _client.from('user_photos').insert({
      'user_id': userId,
      'storage_path': path,
      'position': nextPosition,
      'is_primary': nextPosition == 0,
    });

    await _refresh(userId);
    _log.info('uploadPhoto done — $path (position $nextPosition)');
    return path;
  }

  @override
  Future<void> deletePhoto(String url) async {
    // url == storage path here.
    _log.info('deletePhoto: $url');
    await _client.storage.from(_bucket).remove([url]);
    await _client.from('user_photos').delete().eq('storage_path', url);
    // We don't know which user owns the row from `url` alone; the caller's
    // saveProfile / watchProfile pair will refresh the relevant user.
  }

  @override
  Future<Uint8List?> getPhotoBytes(String url) async {
    try {
      return await _client.storage.from(_bucket).download(url);
    } catch (e, st) {
      _log.warn('getPhotoBytes failed for $url: $e');
      _log.error('getPhotoBytes stack', e, st);
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // Mapping helpers
  // ---------------------------------------------------------------------

  String _formatDate(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  /// Dart enum `Gender.nonBinary` maps to SQL value `'non_binary'`. Every
  /// other enum's name matches the SQL value verbatim.
  String _genderToDb(Gender g) => switch (g) {
        Gender.female => 'female',
        Gender.male => 'male',
        Gender.nonBinary => 'non_binary',
      };

  Gender? _genderFromDb(String? s) => switch (s) {
        'female' => Gender.female,
        'male' => Gender.male,
        'non_binary' => Gender.nonBinary,
        _ => null,
      };

  T? _enumFromName<T extends Enum>(List<T> values, String? name) {
    if (name == null) return null;
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }

  UserProfile _mapToProfile(
    String userId,
    Map<String, dynamic> profileRow,
    Map<String, dynamic>? prefsRow,
    List<dynamic> photoRows,
  ) {
    final birthDateRaw = profileRow['birth_date'] as String?;
    final birthDate =
        birthDateRaw == null ? null : DateTime.tryParse(birthDateRaw);

    Set<Gender> readGenders(List<dynamic>? raw) {
      if (raw == null) return const <Gender>{};
      return raw
          .map((e) => _genderFromDb(e as String?))
          .whereType<Gender>()
          .toSet();
    }

    Set<Intention> readIntentions(List<dynamic>? raw) {
      if (raw == null) return const <Intention>{};
      return raw
          .map((e) => _enumFromName(Intention.values, e as String?))
          .whereType<Intention>()
          .toSet();
    }

    Set<Interest> readInterests(List<dynamic>? raw) {
      if (raw == null) return const <Interest>{};
      return raw
          .map((e) => _enumFromName(Interest.values, e as String?))
          .whereType<Interest>()
          .toSet();
    }

    final photoUrls = photoRows
        .map((row) => (row as Map<String, dynamic>)['storage_path'] as String)
        .toList(growable: false);

    return UserProfile(
      userId: userId,
      firstName: profileRow['first_name'] as String?,
      birthDate: birthDate,
      gender: _genderFromDb(profileRow['gender'] as String?),
      orientation: _enumFromName(
        Orientation.values,
        profileRow['sexual_orientation'] as String?,
      ),
      seekingGenders: readGenders(prefsRow?['seeking_genders'] as List?),
      seekingAgeMin: (prefsRow?['seeking_age_min'] as int?) ?? 18,
      seekingAgeMax: (prefsRow?['seeking_age_max'] as int?) ?? 40,
      maxDistanceKm: (prefsRow?['max_distance_km'] as int?) ?? 50,
      intentions: readIntentions(prefsRow?['intentions'] as List?),
      interests: readInterests(prefsRow?['interests'] as List?),
      availability: _enumFromName(
        Availability.values,
        prefsRow?['availability'] as String?,
      ),
      photoUrls: photoUrls,
    );
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Single repository instance for the app. Cached for the whole lifetime so
/// the in-memory mock state persists across screens.
final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  final available = ref.watch(supabaseAvailableProvider);
  if (available) {
    return SupabaseProfileRepository(ref.watch(supabaseClientProvider));
  }
  return MockProfileRepository();
});
