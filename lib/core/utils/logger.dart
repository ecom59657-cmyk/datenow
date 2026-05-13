import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Minimal logger wrapper. Use this instead of `print` so we have a single
/// place to swap in a real solution (Crashlytics / Sentry / OTLP) later.
class AppLogger {
  const AppLogger(this.tag);

  final String tag;

  void info(Object? message) => _log('INFO', message);
  void warn(Object? message) => _log('WARN', message);
  void error(Object? message, [Object? error, StackTrace? stackTrace]) {
    _log('ERROR', message, error: error, stackTrace: stackTrace);
  }

  void _log(
    String level,
    Object? message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!kDebugMode) return;
    developer.log(
      '$message',
      name: '$tag/$level',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
