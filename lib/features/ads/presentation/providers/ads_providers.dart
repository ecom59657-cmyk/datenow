import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../subscription/presentation/providers/subscription_provider.dart';
import '../../data/consent_service.dart';
import '../../data/rewarded_ad_service.dart';
import '../../domain/ad_ids.dart';

final consentServiceProvider =
    Provider<ConsentService>((_) => const ConsentService());

final rewardedAdServiceProvider = Provider<RewardedAdService>((ref) {
  final service = RewardedAdService(ref.watch(consentServiceProvider));
  ref.onDispose(service.dispose);
  return service;
});

/// Whether this user should be offered ads at all.
///
/// Premium is exempt: paying to remove ads is the clearest thing the
/// subscription buys, and showing them anyway would make the upgrade
/// pitch dishonest. While the subscription state is still loading we
/// answer `false` — better to briefly hide the offer than to flash an
/// ad button at someone who already paid.
final adsEnabledProvider = Provider<bool>((ref) {
  if (!AdIds.isConfigured) return false;
  final subscription = ref.watch(subscriptionStateProvider).asData?.value;
  if (subscription == null) return false;
  return !subscription.isPremium;
});
