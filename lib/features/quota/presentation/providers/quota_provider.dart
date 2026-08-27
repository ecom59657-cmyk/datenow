import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../profile_setup/presentation/providers/profile_provider.dart';
import '../../../subscription/presentation/providers/subscription_provider.dart';
import '../../data/quota_repository.dart';
import '../../domain/quota_status.dart';

/// Async snapshot of today's quota for the currently signed-in user.
///
/// Emits a "no profile" status with `cap: 0` when nobody is logged in so
/// the home screen can keep its current "Find a date" disabled state if
/// ever surfaced before auth. In practice the router redirect blocks that.
final quotaStatusProvider = FutureProvider<QuotaStatus>((ref) {
  final profile = ref.watch(currentProfileProvider).asData?.value;
  if (profile == null) {
    return Future.value(
      QuotaStatus(usedToday: 0, cap: 0, checkedAt: DateTime.now()),
    );
  }
  // The cap depends on the tier, so this snapshot has to follow the
  // subscription stream. While it is still loading we answer "free" —
  // the provider re-emits with the real cap the moment it resolves, and
  // briefly understating the allowance is safer than overstating it.
  final isPremium =
      ref.watch(subscriptionStateProvider).asData?.value.isPremium ?? false;
  return ref
      .watch(quotaRepositoryProvider)
      .currentStatus(profile, isPremium: isPremium);
});
