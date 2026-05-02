import 'package:oauth2/oauth2.dart' as oauth2;

/// Models related to authentication credentials and token refresh results.
final class UserCredentials {
  /// Access token for API authentication.
  final String accessToken;

  /// Refresh token for obtaining new access tokens.
  final String refreshToken;

  /// Expiry time of the access token.
  final DateTime accessTokenExpiry;

  /// Expiry time of the refresh token.
  final DateTime refreshTokenExpiry;

  /// ID token containing user identity information (may be null for non-OIDC flows).
  final String? idToken;

  /// Whether this is a Keycloak offline token (requested via the `offline_access` scope).
  ///
  /// An offline token is a long-lived refresh token stored in Keycloak's database.
  /// When `refresh_expires_in` is `0` in the token response, Keycloak has not imposed
  /// an absolute expiry (the "Offline Session Max Limited" realm setting is off).
  /// The server's idle timeout (default 30 days) still applies server-side but is not
  /// communicated in the token response — a 401 signals actual expiry.
  /// When `true`, [isRefreshExpired] always returns `false`.
  final bool isOfflineToken;

  const UserCredentials({
    required this.accessToken,
    required this.refreshToken,
    required this.accessTokenExpiry,
    required this.refreshTokenExpiry,
    this.idToken,
    this.isOfflineToken = false,
  });

  // ─── Factories ─────────────────────────────────────────────────────────────

  /// Creates a [UserCredentials] from a raw Keycloak token endpoint response.
  factory UserCredentials.fromApi(Map<String, dynamic> json) {
    final refreshExpiresIn = json['refresh_expires_in'] as int;
    final isOffline = refreshExpiresIn == 0;
    return UserCredentials(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String,
      accessTokenExpiry: DateTime.now().add(Duration(seconds: json['expires_in'] as int)),
      // refresh_expires_in == 0 → offline token with no local expiry; use far-future
      // sentinel so local checks never fire — actual expiry is enforced via 401.
      refreshTokenExpiry: isOffline ? DateTime(9999) : DateTime.now().add(Duration(seconds: refreshExpiresIn)),
      idToken: json['id_token'] as String?,
      isOfflineToken: isOffline,
    );
  }

  /// Creates a [UserCredentials] from a locally stored JSON map.
  factory UserCredentials.fromJson(Map<String, dynamic> json) {
    return UserCredentials(
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String,
      accessTokenExpiry: DateTime.parse(json['expiresIn'] as String),
      refreshTokenExpiry: DateTime.parse(json['refreshExpiresIn'] as String),
      idToken: json['idToken'] as String?,
      isOfflineToken: json['isOfflineToken'] as bool? ?? false,
    );
  }

  /// Creates a [UserCredentials] from an [oauth2.Credentials] object.
  ///
  /// The `oauth2` package does not carry a `refresh_expires_in` field, so
  /// [refreshTokenExpiry] defaults to 30 days (Keycloak's typical default).
  /// Set [isOfflineToken] to `true` if you requested the `offline_access` scope.
  factory UserCredentials.fromOAuth2(
    oauth2.Credentials credentials, {
    bool isOfflineToken = false,
    Duration refreshTokenLifetime = const Duration(days: 30),
  }) {
    return UserCredentials(
      accessToken: credentials.accessToken,
      refreshToken: credentials.refreshToken ?? '',
      accessTokenExpiry: credentials.expiration ?? DateTime.now().add(const Duration(minutes: 5)),
      refreshTokenExpiry: isOfflineToken ? DateTime(9999) : DateTime.now().add(refreshTokenLifetime),
      idToken: credentials.idToken,
      isOfflineToken: isOfflineToken,
    );
  }

  // ─── Serialisation ─────────────────────────────────────────────────────────

  /// Serialises to a JSON map for local storage.
  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresIn': accessTokenExpiry.toIso8601String(),
    'refreshExpiresIn': refreshTokenExpiry.toIso8601String(),
    'idToken': idToken,
    'isOfflineToken': isOfflineToken,
  };

  /// Converts to an [oauth2.Credentials] object for use with [oauth2.Client].
  oauth2.Credentials toOAuth2Credentials(Uri tokenEndpoint) => oauth2.Credentials(
    accessToken,
    refreshToken: refreshToken.isNotEmpty ? refreshToken : null,
    idToken: idToken,
    tokenEndpoint: tokenEndpoint,
    expiration: accessTokenExpiry,
  );

  // ─── Expiry checks ─────────────────────────────────────────────────────────

  /// `true` if the access token is expired.
  bool get isAccessExpired => DateTime.now().isAfter(accessTokenExpiry);

  /// `true` if the refresh token is expired.
  ///
  /// Always `false` for offline tokens — the server communicates expiry via 401.
  bool get isRefreshExpired => isOfflineToken ? false : DateTime.now().isAfter(refreshTokenExpiry);

  /// `true` if both access and refresh tokens are expired.
  bool get isExpired => isAccessExpired && isRefreshExpired;
}
