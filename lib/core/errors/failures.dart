/// Domain-level failures. Repositories convert raw exceptions into one of
/// these so the presentation layer can show user-friendly errors without
/// leaking implementation details (Supabase, sockets, etc).
sealed class Failure implements Exception {
  const Failure(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => 'Failure($code): $message';
}

class AuthFailure extends Failure {
  const AuthFailure(super.message, {super.code});
}

class NetworkFailure extends Failure {
  const NetworkFailure(super.message, {super.code});
}

class ServerFailure extends Failure {
  const ServerFailure(super.message, {super.code});
}

class UnknownFailure extends Failure {
  const UnknownFailure([
    String message = 'Something went wrong.',
    String? code,
  ]) : super(message, code: code);
}
