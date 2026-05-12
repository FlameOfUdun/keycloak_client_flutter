import '../enums/log_level.dart';

/// Configuration for [KeycloakClient]. Contains all necessary information to
/// interact with the Keycloak server and customize client behavior.
final class ClientConfig {
  /// The base URL of the Keycloak server, e.g. 'https://auth.example.com'.
  final String baseUrl;

  /// The Keycloak realm to authenticate against.
  final String realm;

  /// The client ID registered in Keycloak. Must be set up for public access or
  final String clientId;

  /// Optional client secret for confidential clients. Not used for public clients.
  final String? clientSecret;

  /// OpenID Connect scopes to request. Must include 'openid' to receive an ID token.
  final List<String> scopes;

  /// Log level for the internal logger. Defaults to [LogLevel.trace] (all messages).
  final LogLevel logLevel;

  /// Timeout for token refresh HTTP requests. If a refresh does not complete
  /// within this duration it is treated as a transient network failure and
  /// retried. Defaults to 15 seconds.
  final Duration refreshTimeout;

  const ClientConfig({
    required this.baseUrl,
    required this.realm,
    required this.clientId,
    this.clientSecret,
    this.scopes = const ['openid', 'email', 'profile'],
    this.logLevel = LogLevel.trace,
    this.refreshTimeout = const Duration(seconds: 15),
  });

  Uri get authorizationEndpoint => Uri.parse('$baseUrl/realms/$realm/protocol/openid-connect/auth');
  Uri get tokenEndpoint => Uri.parse('$baseUrl/realms/$realm/protocol/openid-connect/token');
  Uri get userInfoEndpoint => Uri.parse('$baseUrl/realms/$realm/protocol/openid-connect/userinfo');
  Uri get logoutEndpoint => Uri.parse('$baseUrl/realms/$realm/protocol/openid-connect/logout');
  Uri get accountEndpoint => Uri.parse('$baseUrl/realms/$realm/account');
}
