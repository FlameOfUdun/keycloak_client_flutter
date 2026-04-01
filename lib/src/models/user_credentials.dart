/// Models related to authentication credentials and token refresh results.
final class UserCredentials {
  /// Access token for API authentication.
  final String accessToken;

  /// Expiry time of the access token.
  final String refreshToken;

  /// Expiry time of the refresh token.
  final DateTime accessTokenExpiry;

  /// Refresh token for obtaining new access tokens.
  final DateTime refreshTokenExpiry;

  /// ID token containing user identity information.
  final String idToken;

  /// Whether this is a Keycloak offline token (requested via the `offline_access` scope).
  ///
  /// An offline token is a long-lived refresh token stored in Keycloak's database.
  /// When `refresh_expires_in` is `0` in the token response, Keycloak has not imposed
  /// an absolute expiry (the "Offline Session Max Limited" realm setting is off).
  /// The server's idle timeout (default 30 days) still applies on the server side,
  /// but is not communicated in the token response — a 401 from the server signals
  /// actual expiry. When this flag is `true`, [isRefreshExpired] always returns `false`.
  final bool isOfflineToken;

  const UserCredentials({
    required this.accessToken,
    required this.accessTokenExpiry,
    required this.refreshToken,
    required this.refreshTokenExpiry,
    required this.idToken,
    this.isOfflineToken = false,
  });

  /// Converts the Credentials instance to a JSON map for storage.
  Map<String, dynamic> toJson() {
    return {
      'accessToken': accessToken,
      'expiresIn': accessTokenExpiry.toIso8601String(),
      'refreshToken': refreshToken,
      'refreshExpiresIn': refreshTokenExpiry.toIso8601String(),
      'idToken': idToken,
      'isOfflineToken': isOfflineToken,
    };
  }

  /// Creates a Credentials instance from the API response JSON.
  factory UserCredentials.fromApi(Map<String, dynamic> json) {
    final refreshExpiresIn = json['refresh_expires_in'] as int;
    final isOfflineToken = refreshExpiresIn == 0;
    return UserCredentials(
      accessToken: json['access_token'] as String,
      accessTokenExpiry: DateTime.now().add(Duration(seconds: json['expires_in'] as int)),
      refreshToken: json['refresh_token'] as String,
      // refresh_expires_in == 0 means Keycloak gave no absolute expiry (offline token
      // with "Offline Session Max Limited" OFF). Use a far-future sentinel so local
      // expiry checks never fire; actual expiry is enforced server-side (401 response).
      refreshTokenExpiry: isOfflineToken
          ? DateTime(9999)
          : DateTime.now().add(Duration(seconds: refreshExpiresIn)),
      idToken: json['id_token'] as String,
      isOfflineToken: isOfflineToken,
    );
  }

  /// Creates a Credentials instance from a JSON map, typically used for local storage.
  factory UserCredentials.fromJson(Map<String, dynamic> json) {
    return UserCredentials(
      accessToken: json['accessToken'] as String,
      accessTokenExpiry: DateTime.parse(json['expiresIn'] as String),
      refreshToken: json['refreshToken'] as String,
      refreshTokenExpiry: DateTime.parse(json['refreshExpiresIn'] as String),
      idToken: json['idToken'] as String,
      isOfflineToken: json['isOfflineToken'] as bool? ?? false,
    );
  }

  /// Returns true if the access token is expired.
  bool get isAccessExpired {
    return DateTime.now().isAfter(accessTokenExpiry);
  }

  /// Returns true if the refresh token is expired.
  ///
  /// Always returns `false` for offline tokens ([isOfflineToken] == true) because
  /// no local expiry is available — the server communicates expiry via a 401 response.
  bool get isRefreshExpired {
    if (isOfflineToken) return false;
    return DateTime.now().isAfter(refreshTokenExpiry);
  }

  /// Returns true if both access and refresh tokens are expired.
  bool get isExpired {
    return isAccessExpired && isRefreshExpired;
  }
}