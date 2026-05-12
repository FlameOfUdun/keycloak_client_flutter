import 'dart:convert';

/// Snapshot of an in-progress OAuth2 PKCE grant on web. Persisted to
/// sessionStorage so a full-page redirect to the IdP can be resumed when
/// the callback URL loads the app.
final class PendingGrant {
  final String state;
  final String codeVerifier;
  final String clientId;
  final String? clientSecret;
  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final Uri redirectUri;
  final List<String> scopes;
  final int createdAtMs;

  const PendingGrant({
    required this.state,
    required this.codeVerifier,
    required this.clientId,
    required this.clientSecret,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.redirectUri,
    required this.scopes,
    required this.createdAtMs,
  });

  bool isExpired(Duration ttl) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return now - createdAtMs >= ttl.inMilliseconds;
  }

  Map<String, dynamic> toJson() => {
    'state': state,
    'codeVerifier': codeVerifier,
    'clientId': clientId,
    'clientSecret': clientSecret,
    'authorizationEndpoint': authorizationEndpoint.toString(),
    'tokenEndpoint': tokenEndpoint.toString(),
    'redirectUri': redirectUri.toString(),
    'scopes': scopes,
    'createdAtMs': createdAtMs,
  };

  String toJsonString() => jsonEncode(toJson());

  factory PendingGrant.fromJson(Map<String, dynamic> json) => PendingGrant(
    state: json['state'] as String,
    codeVerifier: json['codeVerifier'] as String,
    clientId: json['clientId'] as String,
    clientSecret: json['clientSecret'] as String?,
    authorizationEndpoint: Uri.parse(json['authorizationEndpoint'] as String),
    tokenEndpoint: Uri.parse(json['tokenEndpoint'] as String),
    redirectUri: Uri.parse(json['redirectUri'] as String),
    scopes: List<String>.from(json['scopes'] as List),
    createdAtMs: json['createdAtMs'] as int,
  );

  factory PendingGrant.fromJsonString(String raw) =>
      PendingGrant.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
