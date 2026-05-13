import 'package:flutter/material.dart';

extension BuildContextX on BuildContext {
  ThemeData get theme => Theme.of(this);
  TextTheme get textTheme => Theme.of(this).textTheme;
  ColorScheme get colors => Theme.of(this).colorScheme;
  MediaQueryData get mq => MediaQuery.of(this);
  Size get size => MediaQuery.sizeOf(this);
  EdgeInsets get safePadding => MediaQuery.paddingOf(this);

  void hideKeyboard() => FocusScope.of(this).unfocus();

  void showSnack(String message) {
    ScaffoldMessenger.of(this)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

extension DurationFormat on Duration {
  /// Formats a duration as `m:ss`. Used by the call countdown.
  String toMmSs() {
    final minutes = inMinutes.remainder(60);
    final seconds = inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
