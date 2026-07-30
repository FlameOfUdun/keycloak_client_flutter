import 'dart:convert';

/// Snapshot of an in-progress OAuth2 PKCE grant on web. Persisted to
/// sessionStorage so a full-page redirect to the IdP can be resumed when
/// the callback URL loads the app.
///
/// Deliberately carries no client secret. This record lives in browser storage,
/// readable by any script on the origin, and a secret there is a secret
/// published — a browser client should be a public one. `WebLoginStrategy`
/// takes the secret from the live `ClientConfig` at callback time instead.
final class PendingGrant {
  final String state;
  final String codeVerifier;
  final String clientId;
  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final Uri redirectUri;
  final List<String> scopes;
  final int createdAtMs;

  /// How long this grant stays valid, in milliseconds.
  ///
  /// Carried on the record rather than held by the store because the store is
  /// built once, at strategy construction, while the TTL comes from the
  /// `WebConfig` passed to `login()`. Persisting it is also what lets
  /// `handleCallback` judge expiry after a full page reload, when the
  /// configuration that started the flow is no longer in memory.
  final int ttlMs;

  const PendingGrant({
    required this.state,
    required this.codeVerifier,
    required this.clientId,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.redirectUri,
    required this.scopes,
    required this.createdAtMs,
    required this.ttlMs,
  });

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch - createdAtMs >= ttlMs;

  Map<String, dynamic> toJson() => {
    'state': state,
    'codeVerifier': codeVerifier,
    'clientId': clientId,
    'authorizationEndpoint': authorizationEndpoint.toString(),
    'tokenEndpoint': tokenEndpoint.toString(),
    'redirectUri': redirectUri.toString(),
    'scopes': scopes,
    'createdAtMs': createdAtMs,
    'ttlMs': ttlMs,
  };

  String toJsonString() => jsonEncode(toJson());

  factory PendingGrant.fromJson(Map<String, dynamic> json) => PendingGrant(
    state: json['state'] as String,
    codeVerifier: json['codeVerifier'] as String,
    clientId: json['clientId'] as String,
    authorizationEndpoint: Uri.parse(json['authorizationEndpoint'] as String),
    tokenEndpoint: Uri.parse(json['tokenEndpoint'] as String),
    redirectUri: Uri.parse(json['redirectUri'] as String),
    scopes: List<String>.from(json['scopes'] as List),
    createdAtMs: json['createdAtMs'] as int,
    ttlMs: json['ttlMs'] as int,
  );

  factory PendingGrant.fromJsonString(String raw) =>
      PendingGrant.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
