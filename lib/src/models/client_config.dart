import '../enums/grant_type.dart';
import 'keycloak_roles.dart';

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

  /// How long a refresh token is assumed to stay valid.
  ///
  /// `package:oauth2` drops the token response's `refresh_expires_in`, so this
  /// cannot be read from the server and is assumed instead. It should match the
  /// realm's **SSO Session Max**. The default of 30 days is Keycloak's own
  /// default for that setting, but a realm that lowers it and an app that does
  /// not follow will keep retrying a refresh token that is already dead —
  /// harmless while online, since the server answers `invalid_grant` and the
  /// session ends properly, but an offline device retries until it reconnects.
  ///
  /// Ignored when `offline_access` is among [scopes]: an offline token has no
  /// local expiry, and only a 401 reveals that the server has dropped it.
  final Duration refreshTokenLifetime;

  /// Timeout for token refresh HTTP requests. If a refresh does not complete
  /// within this duration it is treated as a transient network failure and
  /// retried. Defaults to 15 seconds.
  final Duration refreshTimeout;

  /// How tokens are obtained. Defaults to [GrantType.authorizationCode].
  ///
  /// [GrantType.clientCredentials] turns the client into a service account:
  /// `login()` fetches a token with [clientId] and [clientSecret] and no
  /// browser, and [clientSecret] becomes required.
  final GrantType grantType;

  /// Realm roles the principal must hold. Without all of them, `login()` throws
  /// `KeycloakAccessDeniedException` and a restored or refreshed session ends
  /// as `AuthState.accessDenied`. This is a UX guard, not security: APIs must
  /// enforce roles themselves.
  final Set<String> requiredRealmRoles;

  /// Client roles the principal must hold, by client ID. Same rules as
  /// [requiredRealmRoles].
  final Map<String, Set<String>> requiredClientRoles;

  const ClientConfig({
    required this.baseUrl,
    required this.realm,
    required this.clientId,
    this.clientSecret,
    this.scopes = const ['openid', 'email', 'profile'],
    this.refreshTokenLifetime = const Duration(days: 30),
    this.refreshTimeout = const Duration(seconds: 15),
    this.grantType = GrantType.authorizationCode,
    this.requiredRealmRoles = const {},
    this.requiredClientRoles = const {},
  });

  /// Whether this session requests a Keycloak offline token.
  ///
  /// The only signal available on the client: `package:oauth2` does not surface
  /// the `refresh_expires_in == 0` marker the server sends back.
  bool get isOfflineSession => scopes.contains('offline_access');

  /// Whether this client authenticates as a service account.
  bool get isServiceAccount => grantType == GrantType.clientCredentials;

  /// The required roles [granted] lacks. Empty when all are held.
  KeycloakRoles missingRoles(KeycloakRoles granted) => KeycloakRoles(
    realm: requiredRealmRoles.difference(granted.realm),
    client: {
      for (final MapEntry(key: clientId, value: roles) in requiredClientRoles.entries)
        if (roles.difference(granted.client[clientId] ?? const {}) case final missing when missing.isNotEmpty)
          clientId: missing,
    },
  );

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
