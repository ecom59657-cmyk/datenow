import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../profile_setup/presentation/providers/profile_provider.dart';
import '../../data/subscription_repository.dart';
import '../../domain/subscription_state.dart';

final subscriptionStateProvider = StreamProvider<SubscriptionState>((ref) {
  final profile = ref.watch(currentProfileProvider).asData?.value;
  if (profile == null) {
    return Stream<SubscriptionState>.value(const SubscriptionState.free());
  }
  return ref
      .watch(subscriptionRepositoryProvider)
      .watchState(profile.userId);
});
