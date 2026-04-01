/// Base class for all exceptions thrown by the Keycloak client.
abstract class KeycloakException implements Exception {
  /// Human-readable description of the error.
  final String message;

  /// The underlying error that caused this exception, if any.
  final Object? cause;

  const KeycloakException(this.message, {this.cause});

  @override
  String toString() => cause != null ? '$runtimeType: $message (caused by: $cause)' : '$runtimeType: $message';
}

/// Thrown when a network or connectivity error occurs. The operation may be retried.
final class KeycloakNetworkException extends KeycloakException {
  const KeycloakNetworkException({Object? cause}) : super('A network error occurred', cause: cause);
}

/// Thrown when the Keycloak server returns an HTTP error response.
final class KeycloakServerException extends KeycloakException {
  /// The HTTP status code returned by the server.
  final int statusCode;

  KeycloakServerException(this.statusCode, {Object? cause}) : super('Server returned HTTP $statusCode', cause: cause);
}

/// Thrown when the refresh token is expired or absent and the session cannot be restored.
/// The user must log in again.
final class KeycloakSessionExpiredException extends KeycloakException {
  const KeycloakSessionExpiredException() : super('Session has expired');
}
