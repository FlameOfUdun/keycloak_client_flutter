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
    this.refreshTimeout = const Duration(seconds: 15),
  });

  /// Constructs the standard Keycloak endpoints based on [baseUrl] and [realm].
  Uri get authorizationEndpoint => Uri.parse('$baseUrl/realms/$realm/protocol/openid-connect/auth');

  /// The token endpoint is used for both the initial token exchange and refresh.
  Uri get tokenEndpoint => Uri.parse('$baseUrl/realms/$realm/protocol/openid-connect/token');

  /// The userinfo endpoint is used to fetch user profile information after login.
  Uri get userInfoEndpoint => Uri.parse('$baseUrl/realms/$realm/protocol/openid-connect/userinfo');

  /// The logout endpoint is used to revoke tokens and end the session at Keycloak.
  Uri get logoutEndpoint => Uri.parse('$baseUrl/realms/$realm/protocol/openid-connect/logout');

  /// The account management endpoint is where users can manage their Keycloak account.
  Uri get accountEndpoint => Uri.parse('$baseUrl/realms/$realm/account');

  /// The account credentials endpoint. Returns the list of credential
  /// containers configured for the authenticated user.
  Uri get accountCredentialsEndpoint => Uri.parse('$baseUrl/realms/$realm/account/credentials');
}
