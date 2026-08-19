import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import '../../app/router/app_router.dart';

/// TEMPORARY — QA only, never committed.
const bool kScreenTour = bool.fromEnvironment('SCREEN_TOUR');

void startScreenTour() {
  if (!kDebugMode || !kScreenTour) return;
  Timer(const Duration(seconds: 11), () {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) return;
    debugPrint('[TOUR] → /profile/prompts');
    ctx.go('/profile/prompts');
  });
}
