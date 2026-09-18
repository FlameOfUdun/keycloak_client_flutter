# Roles and Required Roles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the principal's Keycloak roles from the access token, and let `ClientConfig` require roles. A principal without them never becomes `signedIn`, and loses the session if a role is revoked later.

**Architecture:** A pure `KeycloakRoles.fromAccessToken` decodes `realm_access` and `resource_access` from the JWT payload, with no signature check and failing closed. `ClientConfig.missingRoles` compares those roles against the requirements. `KeycloakClient` runs a single check, `_checkRoles(token)`, at login, restore and refresh. A failure revokes the server session and ends the local one, either throwing `KeycloakAccessDeniedException` (login) or moving to the new `AuthState.accessDenied` (restore and refresh).

**Tech Stack:** Dart 3 / Flutter, `package:oauth2`, `package:http/testing.dart` `MockClient`, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-09-18-required-roles-design.md`

**Prerequisite:** `docs/superpowers/plans/2026-09-18-service-account-mode.md` must be fully implemented. This plan uses its `withDependencies(httpClient:)` seam, `ClientConfig.isServiceAccount`, the `FakeStore` / `LoginProbe` / `Slow*Strategy` / `_json` test helpers, and the `logout()` shape it leaves behind.

---

## File map

| File | Change |
|---|---|
| `lib/src/models/keycloak_roles.dart` | **Create.** The `KeycloakRoles` model and JWT decoding. |
| `lib/src/models/client_config.dart` | `requiredRealmRoles`, `requiredClientRoles`, `missingRoles()`. |
| `lib/src/enums/auth_state.dart` | `accessDenied` and `isAccessDenied`. |
| `lib/src/models/keycloak_exception.dart` | `KeycloakAccessDeniedException`. |
| `lib/keycloak_client.dart` | Export; `roles` getter; `_checkRoles`; `_revokeServerSession`; checks at login, restore and refresh. |
| `example/lib/main.dart` | Handle `AuthState.accessDenied`. |
| `test/src/models/keycloak_roles_test.dart` | **Create.** |
| `test/src/models/client_config_test.dart` | `missingRoles` tests. |
| `test/keycloak_client_test.dart` | A `required roles` group. |
| `README.md`, `CHANGELOG.md` | Docs; added to the 4.0.0 entry the service-account plan creates. |

---

### Task 1: `KeycloakRoles`

**Files:**
- Create: `lib/src/models/keycloak_roles.dart`
- Modify: `lib/keycloak_client.dart` (export block)
- Test: `test/src/models/keycloak_roles_test.dart` (create)

- [ ] **Step 1: Write the failing test**

Create `test/src/models/keycloak_roles_test.dart`:

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keycloak_client/keycloak_client.dart';

/// An unsigned JWT carrying [claims]. The header is `{}`.
String jwt(Map<String, dynamic> claims) =>
    'e30.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.sig';

void main() {
  group('KeycloakRoles.fromAccessToken', () {
    test('reads realm and client roles', () {
      final roles = KeycloakRoles.fromAccessToken(jwt({
        'realm_access': {'roles': ['staff', 'user']},
        'resource_access': {
          'my-client': {'roles': ['editor']},
          'account': {'roles': ['view-profile']},
        },
      }));

      expect(roles.realm, {'staff', 'user'});
      expect(roles.client, {'my-client': {'editor'}, 'account': {'view-profile'}});
      expect(roles.hasRealmRole('staff'), isTrue);
      expect(roles.hasRealmRole('admin'), isFalse);
      expect(roles.hasClientRole('my-client', 'editor'), isTrue);
      expect(roles.hasClientRole('other', 'editor'), isFalse);
      expect(roles.isEmpty, isFalse);
    });

    test('a token without role claims has no roles', () {
      final roles = KeycloakRoles.fromAccessToken(jwt({'sub': 'u1'}));

      expect(roles.isEmpty, isTrue);
    });

    test('a malformed token has no roles', () {
      for (final token in ['', 'not-a-jwt', 'a.!!!.c', 'a.${base64Url.encode(utf8.encode('[1]'))}.c']) {
        expect(KeycloakRoles.fromAccessToken(token).isEmpty, isTrue, reason: token);
      }
    });

    test('claims of the wrong type are ignored', () {
      final roles = KeycloakRoles.fromAccessToken(jwt({
        'realm_access': {'roles': 'staff'},
        'resource_access': {'my-client': ['editor'], 'ok': {'roles': ['r', 3]}},
      }));

      expect(roles.realm, isEmpty);
      expect(roles.client, {'ok': {'r'}});
    });
  });
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `flutter test test/src/models/keycloak_roles_test.dart`
Expected: compile error, `Undefined name 'KeycloakRoles'`.

- [ ] **Step 3: Implement**

Create `lib/src/models/keycloak_roles.dart`:

```dart
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
      client: {
        if (resourceAccess is Map)
          for (final MapEntry(:key, :value) in resourceAccess.entries)
            if (key is String && _roles(value).isNotEmpty) key: _roles(value),
      },
    );
  }

  /// The `roles` list inside a `{ "roles": [...] }` claim, or empty.
  static Set<String> _roles(Object? access) {
    if (access is! Map) return const {};
    final roles = access['roles'];
    if (roles is! List) return const {};
    return roles.whereType<String>().toSet();
  }

  bool hasRealmRole(String role) => realm.contains(role);

  bool hasClientRole(String clientId, String role) => client[clientId]?.contains(role) ?? false;

  /// Whether there are no roles at all.
  bool get isEmpty => realm.isEmpty && client.values.every((roles) => roles.isEmpty);

  @override
  String toString() => 'KeycloakRoles(realm: $realm, client: $client)';
}
```

In `lib/keycloak_client.dart`, add this to the export block:

```dart
export 'src/models/keycloak_roles.dart';
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `flutter test test/src/models/keycloak_roles_test.dart`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/src/models/keycloak_roles.dart lib/keycloak_client.dart test/src/models/keycloak_roles_test.dart
git commit -m "feat: add KeycloakRoles, decoded from the access token"
```

---

### Task 2: Required roles on `ClientConfig`

**Files:**
- Modify: `lib/src/models/client_config.dart`
- Test: `test/src/models/client_config_test.dart`

- [ ] **Step 1: Write the failing tests**

Add this group to `main()` in `test/src/models/client_config_test.dart`:

```dart
  group('ClientConfig.missingRoles', () {
    const config = ClientConfig(
      baseUrl: 'http://localhost',
      realm: 'r',
      clientId: 'c',
      requiredRealmRoles: {'staff'},
      requiredClientRoles: {'my-client': {'editor', 'viewer'}},
    );

    test('nothing is missing when every required role is held', () {
      const granted = KeycloakRoles(
        realm: {'staff', 'extra'},
        client: {'my-client': {'editor', 'viewer'}},
      );

      expect(config.missingRoles(granted).isEmpty, isTrue);
    });

    test('reports only what is missing', () {
      const granted = KeycloakRoles(client: {'my-client': {'viewer'}});

      final missing = config.missingRoles(granted);

      expect(missing.realm, {'staff'});
      expect(missing.client, {'my-client': {'editor'}});
    });

    test('a client the principal has no roles in counts as missing', () {
      final missing = config.missingRoles(const KeycloakRoles(realm: {'staff'}));

      expect(missing.client, {'my-client': {'editor', 'viewer'}});
    });

    test('no requirements means nothing is ever missing', () {
      const plain = ClientConfig(baseUrl: 'http://localhost', realm: 'r', clientId: 'c');

      expect(plain.missingRoles(const KeycloakRoles()).isEmpty, isTrue);
    });
  });
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `flutter test test/src/models/client_config_test.dart`
Expected: compile error, `No named parameter with the name 'requiredRealmRoles'`.

- [ ] **Step 3: Implement**

In `lib/src/models/client_config.dart`, add this import:

```dart
import 'keycloak_roles.dart';
```

Add these fields after `grantType`:

```dart
  /// Realm roles the principal must hold. Without all of them, `login()` throws
  /// `KeycloakAccessDeniedException` and a restored or refreshed session ends
  /// as `AuthState.accessDenied`. This is a UX guard, not security: APIs must
  /// enforce roles themselves.
  final Set<String> requiredRealmRoles;

  /// Client roles the principal must hold, by client ID. Same rules as
  /// [requiredRealmRoles].
  final Map<String, Set<String>> requiredClientRoles;
```

Add these constructor parameters after `this.grantType = GrantType.authorizationCode,`:

```dart
    this.requiredRealmRoles = const {},
    this.requiredClientRoles = const {},
```

Add this method after `isServiceAccount`:

```dart
  /// The required roles [granted] lacks. Empty when all are held.
  KeycloakRoles missingRoles(KeycloakRoles granted) => KeycloakRoles(
    realm: requiredRealmRoles.difference(granted.realm),
    client: {
      for (final MapEntry(key: clientId, value: roles) in requiredClientRoles.entries)
        if (roles.difference(granted.client[clientId] ?? const {}) case final missing when missing.isNotEmpty)
          clientId: missing,
    },
  );
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `flutter test test/src/models/client_config_test.dart`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/src/models/client_config.dart test/src/models/client_config_test.dart
git commit -m "feat: add required roles to ClientConfig"
```

---

### Task 3: `AuthState.accessDenied` and `KeycloakAccessDeniedException`

**Files:**
- Modify: `lib/src/enums/auth_state.dart`
- Modify: `lib/src/models/keycloak_exception.dart`
- Modify: `example/lib/main.dart:109-114`

- [ ] **Step 1: Implement**

In `lib/src/enums/auth_state.dart`, replace `sessionExpired;` with:

```dart
  sessionExpired,

  /// Session ended because the principal lacks a role listed in
  /// `ClientConfig.requiredRealmRoles` / `requiredClientRoles`, either at
  /// restore or because it was revoked while signed in.
  accessDenied;
```

Add this getter after `isSessionExpired`:

```dart
  bool get isAccessDenied => this == AuthState.accessDenied;
```

At the end of `lib/src/models/keycloak_exception.dart`, add:

```dart
/// Thrown by `login()` and `handleWebCallback()` when the principal lacks a
/// required role. The Keycloak session has already been ended.
final class KeycloakAccessDeniedException extends KeycloakException {
  /// The required roles that were not granted.
  final KeycloakRoles missing;

  KeycloakAccessDeniedException(this.missing) : super('Missing required roles: $missing');
}
```

Add this import at the top of the same file:

```dart
import 'keycloak_roles.dart';
```

In `example/lib/main.dart`, add this arm to the `AuthState` switch after the `sessionExpired` arm:

```dart
          AuthState.accessDenied => _LoginScreen(client: client),
```

- [ ] **Step 2: Analyze**

Run: `flutter analyze`
Expected: `No issues found!`. Without the example arm, analysis reports a non-exhaustive switch.

- [ ] **Step 3: Commit**

```bash
git add lib/src/enums/auth_state.dart lib/src/models/keycloak_exception.dart example/lib/main.dart
git commit -m "feat: add AuthState.accessDenied and KeycloakAccessDeniedException"
```

---

### Task 4: Enforce roles in `KeycloakClient`

**Files:**
- Modify: `lib/keycloak_client.dart`
- Test: `test/keycloak_client_test.dart`

- [ ] **Step 1: Write the failing tests**

In `test/keycloak_client_test.dart`, add these helpers above `main()`. They reuse `_json` from the service-account plan, and `dart:convert` is already imported there.

```dart
/// An unsigned JWT carrying [claims].
String _jwt(Map<String, dynamic> claims) =>
    'e30.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.sig';

String _tokenWithRealmRoles(List<String> roles) => _jwt({'sub': 'u1', 'realm_access': {'roles': roles}});

/// Serves userinfo and records every request (for the /logout assertion).
final class FakeUserServer {
  final requests = <http.Request>[];
  late final http.Client client = MockClient((request) async {
    requests.add(request);
    if (request.url.path.endsWith('/userinfo')) return _json({'sub': 'u1', 'preferred_username': 'alice'});
    return http.Response('', 204);
  });

  bool get calledLogout => requests.any((r) => r.url.path.endsWith('/logout'));
}

oauth2.Client _clientWithToken(String accessToken, http.Client transport) => oauth2.Client(
  oauth2.Credentials(
    accessToken,
    refreshToken: 'valid-refresh',
    expiration: DateTime.now().add(const Duration(minutes: 5)),
    tokenEndpoint: Uri.parse('http://localhost/token'),
  ),
  httpClient: transport,
);

ClientConfig _staffOnly() => const ClientConfig(
  baseUrl: 'http://localhost',
  realm: 'test',
  clientId: 'app',
  requiredRealmRoles: {'staff'},
);

UserCredentials _storedToken(String accessToken, {bool accessExpired = false}) => UserCredentials(
  accessToken: accessToken,
  refreshToken: 'valid-refresh',
  accessTokenExpiry: accessExpired
      ? DateTime.now().subtract(const Duration(minutes: 1))
      : DateTime.now().add(const Duration(minutes: 5)),
  refreshTokenExpiry: DateTime.now().add(const Duration(days: 30)),
);
```

Add this group at the end of `main()`:

```dart
  group('required roles', () {
    KeycloakClient loginClient(ClientConfig config, FakeStore store, oauth2.Client result) {
      final probe = LoginProbe()..completer.complete(result);
      return KeycloakClient.withDependencies(
        clientConfig: config,
        credentialsStorage: store,
        desktopLoginStrategy: SlowDesktopStrategy(probe),
        mobileLoginStrategy: SlowMobileStrategy(probe),
      );
    }

    test('a principal holding the roles signs in and they are exposed', () async {
      final server = FakeUserServer();
      final client = loginClient(_staffOnly(), FakeStore(), _clientWithToken(_tokenWithRealmRoles(['staff']), server.client));

      await client.login();

      expect(client.authState, AuthState.signedIn);
      expect(client.roles?.hasRealmRole('staff'), isTrue);

      client.dispose();
    });

    test('login without a required role throws and leaves nothing behind', () async {
      final server = FakeUserServer();
      final store = FakeStore();
      final client = loginClient(_staffOnly(), store, _clientWithToken(_tokenWithRealmRoles(['user']), server.client));

      await expectLater(
        client.login(),
        throwsA(isA<KeycloakAccessDeniedException>().having((e) => e.missing.realm, 'missing.realm', {'staff'})),
      );

      expect(client.authState, AuthState.signedOut);
      expect(client.roles, isNull);
      expect(store.creds, isNull);
      expect(server.calledLogout, isTrue, reason: 'the Keycloak session was left open');

      client.dispose();
    });

    test('without requirements a role-less principal signs in', () async {
      final server = FakeUserServer();
      final client = loginClient(
        const ClientConfig(baseUrl: 'http://localhost', realm: 'test', clientId: 'app'),
        FakeStore(),
        _clientWithToken(_jwt({'sub': 'u1'}), server.client),
      );

      await client.login();

      expect(client.authState, AuthState.signedIn);
      expect(client.roles?.isEmpty, isTrue);

      client.dispose();
    });

    test('restoring a session without a required role ends as accessDenied', () async {
      final server = FakeUserServer();
      final store = FakeStore(creds: _storedToken(_tokenWithRealmRoles(['user'])), user: const UserInfo(id: 'u1'));
      final client = KeycloakClient.withDependencies(
        clientConfig: _staffOnly(),
        credentialsStorage: store,
        httpClient: server.client,
      );

      await client.waitForInitialization();

      expect(client.authState, AuthState.accessDenied);
      expect(store.creds, isNull);
      expect(server.calledLogout, isTrue);

      client.dispose();
    });

    test('a refresh that loses a required role ends the session', () async {
      final server = FakeUserServer();
      final store = FakeStore(creds: _storedToken(_tokenWithRealmRoles(['staff'])), user: const UserInfo(id: 'u1'));
      final client = KeycloakClient.withDependencies(
        clientConfig: _staffOnly(),
        credentialsStorage: store,
        httpClient: server.client,
        tokenRefreshOperation: (_, _) async => _clientWithToken(_tokenWithRealmRoles(['user']), server.client),
      );
      await client.waitForInitialization();
      expect(client.authState, AuthState.signedIn);

      final rotations = <void>[];
      final sub = client.onTokenRefreshed.listen(rotations.add);
      store.creds = _storedToken(_tokenWithRealmRoles(['staff']), accessExpired: true);
      final token = await client.getAuthToken();
      await Future.delayed(const Duration(milliseconds: 50));

      expect(token, isNull, reason: 'a token without the role was handed out');
      expect(client.authState, AuthState.accessDenied);
      expect(client.roles, isNull);
      expect(rotations, isEmpty);

      await sub.cancel();
      client.dispose();
    });

    test('logout clears roles', () async {
      final server = FakeUserServer();
      final client = loginClient(_staffOnly(), FakeStore(), _clientWithToken(_tokenWithRealmRoles(['staff']), server.client));
      await client.login();

      await client.logout();

      expect(client.roles, isNull);

      client.dispose();
    });
  });
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `flutter test test/keycloak_client_test.dart --plain-name "required roles"`
Expected: compile error, `The getter 'roles' isn't defined`.

- [ ] **Step 3: Implement: state, helpers and the `roles` getter**

In `lib/keycloak_client.dart`, add this import:

```dart
import 'src/models/keycloak_roles.dart';
```

Add this field after `bool _disposed = false;`:

```dart
  KeycloakRoles? _roles;
```

Add this getter after `AuthState get authState => ...;`:

```dart
  /// The principal's Keycloak roles, from the current access token. `null`
  /// while no session exists. Updated on every refresh; listen to
  /// [onTokenRefreshed] to react to changes.
  KeycloakRoles? get roles => _roles;
```

Add these helpers after `_endSession`:

```dart
  /// Checks [accessToken] against the required roles. Returns the missing ones,
  /// or `null` when all are held, in which case the token's roles become [roles].
  KeycloakRoles? _checkRoles(String accessToken) {
    final granted = KeycloakRoles.fromAccessToken(accessToken);
    final missing = _clientConfig.missingRoles(granted);
    if (!missing.isEmpty) {
      _logger.warning('Required roles missing: $missing');
      return missing;
    }
    _roles = granted;
    return null;
  }

  /// Revokes the stored session at Keycloak. A service account has no refresh
  /// token and no browser session, so there is nothing to revoke.
  Future<void> _revokeServerSession() async {
    if (_clientConfig.isServiceAccount) return;
    final stored = await _credentialsStorage.getCredentials();
    if (stored == null) return;
    await _tokenService.revokeSession(
      logoutEndpoint: _clientConfig.logoutEndpoint,
      clientId: _clientConfig.clientId,
      refreshToken: stored.refreshToken,
      idToken: stored.idToken,
    );
  }

  /// Ends the session at Keycloak and locally, landing in [reason].
  Future<void> _denyAccess(AuthState reason) async {
    await _revokeServerSession();
    await _endSession(reason);
  }
```

Replace `_endSession` with:

```dart
  Future<void> _endSession(AuthState reason) async {
    _roles = null;
    _tokenService.invalidate();
    await _credentialsStorage.clear();
    _sessionManager.endSession(reason);
  }
```

Replace the body of `logout()` from `final stored = ...` through the closing brace of its `if` with:

```dart
    await _revokeServerSession();
```

- [ ] **Step 4: Implement: the check at login**

In `_finalizeLogin`, insert this directly after `await _credentialsStorage.setCredentials(credentials);`:

```dart
    final missing = _checkRoles(credentials.accessToken);
    if (missing != null) {
      // signedOut, not accessDenied: the caller gets the exception, and the
      // app never entered a session to be denied from.
      await _denyAccess(AuthState.signedOut);
      throw KeycloakAccessDeniedException(missing);
    }
```

- [ ] **Step 5: Implement: the check at restore**

In `initialize()`, in the `if (stored.isAccessExpired) { ... }` branch, replace:

```dart
            if (result is RefreshPermanentFailure) return;
```

with:

```dart
            if (result is RefreshPermanentFailure) return;
            // Offline start: judge the stored token, as the restore below does.
            final token = result is RefreshSuccess ? result.credentials.accessToken : stored.accessToken;
            if (_checkRoles(token) != null) {
              await _denyAccess(AuthState.accessDenied);
              return;
            }
```

In the `else` branch, insert this as its first line, before `_sessionManager.beginSession(user);`:

```dart
            if (_checkRoles(stored.accessToken) != null) {
              await _denyAccess(AuthState.accessDenied);
              return;
            }
```

- [ ] **Step 6: Implement: the check on refresh**

Replace `_handleTokenRefreshed` with:

```dart
  void _handleTokenRefreshed() {
    if (!_sessionManager.authState.isSignedIn) return;
    final token = _tokenService.oauthClient?.credentials.accessToken;
    if (token != null && _checkRoles(token) != null) {
      _denyAccess(AuthState.accessDenied).ignore();
      return;
    }
    if (_tokenRefreshed.isClosed) return;
    _tokenRefreshed.add(null);
  }
```

In `getAuthToken()`, replace the `RefreshSuccess` arm with:

```dart
      // The refresh handler has already started ending the session if a role
      // was lost; don't hand the caller a token for it in the meantime.
      RefreshSuccess(:final credentials) => _clientConfig.missingRoles(KeycloakRoles.fromAccessToken(credentials.accessToken)).isEmpty
          ? credentials.accessToken
          : null,
```

In `refreshToken()`, replace the `RefreshSuccess` case with:

```dart
      case RefreshSuccess(:final credentials):
        final missing = _clientConfig.missingRoles(KeycloakRoles.fromAccessToken(credentials.accessToken));
        if (!missing.isEmpty) throw KeycloakAccessDeniedException(missing);
        _reloadUser().ignore();
```

- [ ] **Step 7: Run the tests and confirm they pass**

Run: `flutter test test/keycloak_client_test.dart test/src`
Expected: all pass, including every earlier test.

- [ ] **Step 8: Commit**

```bash
git add lib/keycloak_client.dart test/keycloak_client_test.dart
git commit -m "feat: expose roles and enforce required roles"
```

---

### Task 5: Documentation and version

**Files:**
- Modify: `README.md`, `CHANGELOG.md`

- [ ] **Step 1: README**

In the `ClientConfig` fields list, add these after `grantType`:

```markdown
- `requiredRealmRoles` / `requiredClientRoles`: roles the principal must hold, see [Roles](#roles)
```

Insert this section before `## Dev Redirect Helper`:

````markdown
## Roles

`client.roles` exposes the principal's Keycloak roles, read from the access
token (`realm_access`, `resource_access`). It is `null` while signed out and
updates on every refresh.

```dart
client.roles?.hasRealmRole('staff');
client.roles?.hasClientRole('my-client', 'editor');
```

To admit only principals with certain roles:

```dart
ClientConfig(
  ...,
  requiredRealmRoles: {'staff'},
  requiredClientRoles: {'my-client': {'editor'}},
)
```

- `login()` without them ends the Keycloak session and throws
  `KeycloakAccessDeniedException` (`e.missing` lists what was lacking).
- A restored session without them, or one whose role is revoked while signed
  in, ends as `AuthState.accessDenied`.

This is a UX guard. The token's signature isn't checked, and anyone can modify
an app, so your API must enforce roles itself. To block the login in Keycloak
itself, add a *Condition – user role* + *Deny access* step to the browser
flow.
````

In `## Auth States`, add `- \`AuthState.accessDenied\``. In `## Exceptions`, add:

```markdown
- `KeycloakAccessDeniedException` — `login()` found the principal lacks a required role; the session was already ended
```

In `## Main API`, add:

```markdown
- `roles`: the principal's realm and client roles, `null` while signed out
```

- [ ] **Step 2: CHANGELOG and version**

The service-account plan already created the `## 4.0.0` entry and set
`version: 4.0.0` in `pubspec.yaml`. Both features ship in this one release, so
don't add a new heading or change the version. In the existing `## 4.0.0`
entry, insert this section directly under the `## 4.0.0` heading, above
`### New`:

```markdown
### Breaking

- `AuthState.accessDenied` is a new value. Exhaustive `switch`es over
  `AuthState` need an arm for it.
```

Then append these bullets to the end of that entry's `### New` list:

```markdown
- `KeycloakClient.roles`: realm and client roles from the access token,
  updated on every refresh.
- `ClientConfig.requiredRealmRoles` / `requiredClientRoles`: a principal
  without them is rejected at login with `KeycloakAccessDeniedException`, and a
  restored or refreshed session without them ends as `AuthState.accessDenied`.
  The Keycloak session is revoked in both cases.
```

- [ ] **Step 3: Analyze and run the full suite**

Run: `flutter analyze && flutter test test/keycloak_client_test.dart test/src`
Expected: `No issues found!`, and all tests pass.

- [ ] **Step 4: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: roles and required roles, 4.0.0"
```
