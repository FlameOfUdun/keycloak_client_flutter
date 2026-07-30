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
  /// `package:oauth2` discards the token response's `refresh_expires_in`, so
  /// neither the real refresh lifetime nor the `refresh_expires_in == 0` marker
  /// that identifies an offline token survives the exchange. Both therefore
  /// have to be told to this factory rather than read from [credentials]:
  /// [isOfflineToken] from whether `offline_access` was requested, and
  /// [refreshTokenLifetime] from the realm's SSO Session Max.
  ///
  /// Getting [isOfflineToken] wrong is not cosmetic. An offline session stored
  /// as a normal one gets a real [refreshTokenExpiry], and once that passes,
  /// `initialize()` ends a session Keycloak would still have honoured.
  factory UserCredentials.fromOAuth2(
    oauth2.Credentials credentials, {
    bool isOfflineToken = false,
    Duration refreshTokenLifetime = const Duration(days: 30),
  }) {
    return UserCredentials(
      accessToken: credentials.accessToken,
      refreshToken: credentials.refreshToken ?? '',
      accessTokenExpiry:
          credentials.expiration ??
          DateTime.now().add(const Duration(minutes: 5)),
      refreshTokenExpiry: isOfflineToken
          ? DateTime(9999)
          : DateTime.now().add(refreshTokenLifetime),
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
  oauth2.Credentials toOAuth2Credentials(Uri tokenEndpoint) =>
      oauth2.Credentials(
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
  bool get isRefreshExpired =>
      isOfflineToken ? false : DateTime.now().isAfter(refreshTokenExpiry);

  /// `true` if both access and refresh tokens are expired.
  bool get isExpired => isAccessExpired && isRefreshExpired;
}
