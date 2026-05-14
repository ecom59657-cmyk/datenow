import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/active_match.dart';

/// Holds the currently-active candidate match across the matching → call →
/// post-call flow. Set by the matching screen, read by the call + post-call
/// screens, and cleared when the user goes home or starts another search.
final activeMatchProvider = StateProvider<ActiveMatch?>((ref) => null);
