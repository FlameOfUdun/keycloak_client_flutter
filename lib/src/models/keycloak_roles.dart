import 'dart:convert';

/// Keycloak roles held by the signed-in principal, read from the access token.
///
/// The token's signature is not verified: it came straight from the token
/// endpoint, and these roles drive UX only. APIs must enforce roles themselves.
final class KeycloakRoles {
  /// Realm roles (`realm_access.roles`).
  final Set<String> realm;

  /// Client roles by client ID (`resource_access.<clientId>.roles`).
  final Map<String, Set<String>> client;

  const KeycloakRoles({this.realm = const {}, this.client = const {}});

  /// Decodes the roles in [accessToken]. A token that cannot be decoded, or
  /// that lacks the claims, yields no roles, so a required-role check on it
  /// fails closed.
  factory KeycloakRoles.fromAccessToken(String accessToken) {
    final Map<String, dynamic> claims;
    try {
      final parts = accessToken.split('.');
      if (parts.length != 3) return const KeycloakRoles();
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      if (payload is! Map<String, dynamic>) return const KeycloakRoles();
      claims = payload;
    } on FormatException {
      return const KeycloakRoles();
    }

    final resourceAccess = claims['resource_access'];
    return KeycloakRoles(
      realm: _roles(claims['realm_access']),
      client: Map.unmodifiable({
        if (resourceAccess is Map)
          for (final MapEntry(:key, :value) in resourceAccess.entries)
            if (key is String && _roles(value).isNotEmpty) key: _roles(value),
      }),
    );
  }

  /// The `roles` list inside a `{ "roles": [...] }` claim, or empty. The set
  /// is unmodifiable, so [KeycloakRoles.fromAccessToken] cannot be mutated.
  static Set<String> _roles(Object? access) {
    if (access is! Map) return const {};
    final roles = access['roles'];
    if (roles is! List) return const {};
    return Set.unmodifiable(roles.whereType<String>());
  }

  bool hasRealmRole(String role) => realm.contains(role);

  bool hasClientRole(String clientId, String role) => client[clientId]?.contains(role) ?? false;

  /// Whether there are no roles at all.
  bool get isEmpty => realm.isEmpty && client.values.every((roles) => roles.isEmpty);

  @override
  String toString() => 'KeycloakRoles(realm: $realm, client: $client)';
}
