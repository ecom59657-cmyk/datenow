import 'package:datenow/core/utils/extensions.dart';
import 'package:datenow/core/utils/validators.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Validators', () {
    test('email validator', () {
      expect(Validators.email(''), isNotNull);
      expect(Validators.email('not-an-email'), isNotNull);
      expect(Validators.email('hi@datenow.app'), isNull);
    });

    test('password validator', () {
      expect(Validators.password(''), isNotNull);
      expect(Validators.password('short'), isNotNull);
      expect(Validators.password('longenoughpw'), isNull);
    });

    test('required validator', () {
      expect(Validators.required(''), isNotNull);
      expect(Validators.required('  '), isNotNull);
      expect(Validators.required('value'), isNull);
    });
  });

  group('Duration extensions', () {
    test('toMmSs formats correctly', () {
      expect(const Duration(minutes: 5).toMmSs(), '5:00');
      expect(const Duration(seconds: 9).toMmSs(), '0:09');
      expect(const Duration(minutes: 1, seconds: 23).toMmSs(), '1:23');
    });
  });
}
