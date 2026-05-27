/// Domain-level failures. Repositories convert raw exceptions into one of
/// these so the presentation layer can show user-friendly errors without
/// leaking implementation details (Supabase, sockets, etc).
sealed class Failure implements Exception {
  const Failure(this.message, {this.code, this.originalMessage});

  /// Short, mostly English, domain message. NEVER shown to end users
  /// directly — the UI layer picks an `AppLocalizations` string by
  /// switching on [code] instead.
  final String message;

  /// Stable code the UI switches on. Always set by the repository so
  /// presentation never has to scrape [message] for substrings.
  final String? code;

  /// Optional raw message from the underlying exception (Supabase
  /// AuthException, Postgrest error, etc). Kept so debug logs and
  /// crash reports keep the technical detail even after the UI layer
  /// replaces the user-facing string with a humane one.
  final String? originalMessage;

  @override
  String toString() {
    final base = 'Failure($code): $message';
    if (originalMessage == null || originalMessage == message) return base;
    return '$base [raw: $originalMessage]';
  }
}

class AuthFailure extends Failure {
  const AuthFailure(super.message, {super.code, super.originalMessage});
}

class NetworkFailure extends Failure {
  const NetworkFailure(super.message, {super.code, super.originalMessage});
}

class ServerFailure extends Failure {
  const ServerFailure(super.message, {super.code, super.originalMessage});
}

class UnknownFailure extends Failure {
  const UnknownFailure([
    String message = 'Something went wrong.',
    String? code,
  ]) : super(message, code: code);
}
