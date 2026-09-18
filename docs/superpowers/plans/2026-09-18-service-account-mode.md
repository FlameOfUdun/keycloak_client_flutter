# Service-Account Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `KeycloakClient` authenticate as a Keycloak service account (OAuth2 client-credentials grant) through its existing public API. The only switch is a new `ClientConfig.grantType` field.

**Architecture:** In service-account mode, `login()` runs `oauth2.clientCredentialsGrant` instead of a platform login strategy. `TokenService`'s refresh operation becomes "run the grant again". Credentials get no local refresh expiry, using the path offline tokens already take. `invalid_client` and `unauthorized_client` become permanent failures. Methods that only make sense for a human user throw `UnsupportedError`.

**Tech Stack:** Dart 3 / Flutter, `package:oauth2` 2.0.5, `package:http` (`MockClient` from `package:http/testing.dart` in tests), `flutter_test`, `mocktail`.

**Spec:** `docs/superpowers/specs/2026-09-18-service-account-mode-design.md`

**Baseline:** `flutter test test/keycloak_client_test.dart test/src` → 46 tests, all passing.

---

## File map

| File | Change |
|---|---|
| `lib/src/enums/grant_type.dart` | **Create.** The `GrantType` enum. |
| `lib/src/models/client_config.dart` | Add the `grantType` field and an `isServiceAccount` getter. |
| `lib/src/core/token_service.dart` | Add a `permanentAuthErrors` constructor parameter. |
| `lib/keycloak_client.dart` | Export `GrantType`; secret check; client-credentials login; refresh operation; offline flag; `httpClient` test seam; `logout`/unsupported branches. |
| `pubspec.yaml` | Move `http` to `dependencies`; version 4.0.0 (shared with the required-roles plan). |
| `test/src/models/client_config_test.dart` | **Create.** |
| `test/src/core/token_service_test.dart` | Add tests for `permanentAuthErrors`. |
| `test/keycloak_client_test.dart` | Add a `service account mode` group. |
| `test/live/keycloak_live_test.dart` | Add one live test. |
| `README.md`, `CHANGELOG.md` | Documentation. |

---

### Task 1: `GrantType` and `ClientConfig.grantType`

**Files:**
- Create: `lib/src/enums/grant_type.dart`
- Modify: `lib/src/models/client_config.dart`
- Modify: `lib/keycloak_client.dart` (exports block, near line 26)
- Test: `test/src/models/client_config_test.dart` (create)

- [ ] **Step 1: Write the failing test**

Create `test/src/models/client_config_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:keycloak_client/keycloak_client.dart';

void main() {
  group('ClientConfig.grantType', () {
    test('defaults to authorizationCode, so existing configs are unchanged', () {
      const config = ClientConfig(baseUrl: 'http://localhost', realm: 'r', clientId: 'c');

      expect(config.grantType, GrantType.authorizationCode);
      expect(config.isServiceAccount, isFalse);
    });

    test('clientCredentials marks the config as a service account', () {
      const config = ClientConfig(
        baseUrl: 'http://localhost',
        realm: 'r',
        clientId: 'c',
        clientSecret: 's',
        grantType: GrantType.clientCredentials,
      );

      expect(config.isServiceAccount, isTrue);
    });

    test('a secret alone does not switch the mode', () {
      // Confidential clients pass a secret for browser login and must keep it.
      const config = ClientConfig(baseUrl: 'http://localhost', realm: 'r', clientId: 'c', clientSecret: 's');

      expect(config.isServiceAccount, isFalse);
    });
  });
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `flutter test test/src/models/client_config_test.dart`
Expected: compile error, `Undefined name 'GrantType'`.

- [ ] **Step 3: Implement**

Create `lib/src/enums/grant_type.dart`:

```dart
/// How [KeycloakClient] obtains its tokens.
enum GrantType {
  /// Interactive Authorization Code + PKCE login in a browser. The default.
  authorizationCode,

  /// OAuth2 client-credentials grant: the client authenticates as its own
  /// Keycloak service account with `clientId` + `clientSecret`. There is no
  /// browser and no human user.
  ///
  /// Requires "Client authentication" and "Service accounts roles" enabled on
  /// the Keycloak client. Never ship the secret in a public app build.
  clientCredentials,
}
```

In `lib/src/models/client_config.dart`, add at the top of the file:

```dart
import '../enums/grant_type.dart';
```

Add the field after `refreshTimeout`:

```dart
  /// How tokens are obtained. Defaults to [GrantType.authorizationCode].
  ///
  /// [GrantType.clientCredentials] turns the client into a service account:
  /// `login()` fetches a token with [clientId] and [clientSecret] and no
  /// browser, and [clientSecret] becomes required.
  final GrantType grantType;
```

Add `this.grantType = GrantType.authorizationCode,` as the last constructor parameter, after `this.refreshTimeout = ...`. Then add this getter after `isOfflineSession`:

```dart
  /// Whether this client authenticates as a service account.
  bool get isServiceAccount => grantType == GrantType.clientCredentials;
```

In `lib/keycloak_client.dart`, add this to the export block after `export 'src/enums/auth_state.dart';`:

```dart
export 'src/enums/grant_type.dart';
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `flutter test test/src/models/client_config_test.dart`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/src/enums/grant_type.dart lib/src/models/client_config.dart lib/keycloak_client.dart test/src/models/client_config_test.dart
git commit -m "feat: add ClientConfig.grantType"
```

---

### Task 2: Configurable permanent auth errors in `TokenService`

**Files:**
- Modify: `lib/src/core/token_service.dart` (fields, constructor, and the `on oauth2.AuthorizationException` clause in `_doRefresh`)
- Test: `test/src/core/token_service_test.dart`

- [ ] **Step 1: Write the failing tests**

In `test/src/core/token_service_test.dart`, extend the `_makeService` helper with one named parameter and pass it through:

```dart
  TokenService _makeService(
    Future<oauth2.Client> Function(oauth2.Client, List<String>) refreshOp, {
    Duration refreshTimeout = const Duration(seconds: 15),
    Duration refreshTokenLifetime = const Duration(days: 30),
    bool isOfflineSession = false,
    Set<String>? permanentAuthErrors,
  }) {
    return TokenService(
      store: store,
      scopes: const ['openid'],
      refreshTokenLifetime: refreshTokenLifetime,
      isOfflineSession: isOfflineSession,
      onPermanentFailure: () async => permanentCalls++,
      onRecovery: () => recoveryCalls++,
      onTokenRefreshed: () => refreshedCalls++,
      logger: logger,
      refreshOperation: refreshOp,
      refreshTimeout: refreshTimeout,
      permanentAuthErrors: permanentAuthErrors,
    );
  }
```

Add a new group at the end of `main()`:

```dart
  group('permanentAuthErrors', () {
    test('by default invalid_client is transient', () async {
      when(() => store.getCredentials()).thenAnswer((_) async => _validCreds());
      final service = _makeService(
        (_, __) async => throw oauth2.AuthorizationException('invalid_client', null, null),
      );
      service.setClient(oauthClient);

      final result = await service.attemptRefresh();

      expect(result, isA<RefreshTransientFailure>());
      expect(permanentCalls, 0);
      service.dispose();
    });

    test('a listed error ends the session without retrying', () async {
      final service = _makeService(
        (_, __) async => throw oauth2.AuthorizationException('invalid_client', null, null),
        permanentAuthErrors: const {'invalid_grant', 'invalid_client'},
      );
      service.setClient(oauthClient);

      final result = await service.attemptRefresh();

      expect(result, isA<RefreshPermanentFailure>());
      expect(permanentCalls, 1);
      service.dispose();
    });
  });
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `flutter test test/src/core/token_service_test.dart`
Expected: compile error, `No named parameter with the name 'permanentAuthErrors'`.

- [ ] **Step 3: Implement**

In `lib/src/core/token_service.dart`, add this field after `final bool _isOfflineSession;`:

```dart
  final Set<String> _permanentAuthErrors;
```

Add this constructor parameter after `bool isOfflineSession = false,`:

```dart
    Set<String>? permanentAuthErrors,
```

Add this initializer after `_isOfflineSession = isOfflineSession,`:

```dart
       _permanentAuthErrors = permanentAuthErrors ?? const {'invalid_grant'},
```

Replace the `on oauth2.AuthorizationException` clause in `_doRefresh` with:

```dart
    } on oauth2.AuthorizationException catch (e, st) {
      // invalid_grant: the refresh token is revoked or expired. A service
      // account also lists invalid_client / unauthorized_client: its secret
      // was rotated or the client reconfigured, and no retry can fix that.
      if (_permanentAuthErrors.contains(e.error)) {
        _logger.warning('Refresh rejected permanently (${e.error}).');
        await onPermanentFailure();
        return const RefreshPermanentFailure();
      }
      _logger.severe('Authorization error during refresh, retrying in 30s.', e, st);
      return await _handleTransientFailure(e);
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `flutter test test/src/core/token_service_test.dart`
Expected: all pass, including the existing `invalid_grant` test.

- [ ] **Step 5: Commit**

```bash
git add lib/src/core/token_service.dart test/src/core/token_service_test.dart
git commit -m "feat: let TokenService treat more auth errors as permanent"
```

---

### Task 3: Client-credentials login and renewal in `KeycloakClient`

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/keycloak_client.dart`
- Test: `test/keycloak_client_test.dart`

- [ ] **Step 1: Move `http` to `dependencies`**

In `pubspec.yaml`, delete `  http: ^1.6.0` from `dev_dependencies` and add it under `dependencies` after `oauth2: ^2.0.5`:

```yaml
  http: ^1.6.0
```

Run: `flutter pub get`
Expected: `Got dependencies!`

- [ ] **Step 2: Write the failing tests**

In `test/keycloak_client_test.dart`, add these imports:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
```

Add these helpers above `void main()`:

```dart
http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// Stands in for Keycloak's token and userinfo endpoints for the
/// client-credentials grant. Tokens are numbered by request, so a test can
/// tell a fresh grant from a cached token.
final class FakeKeycloak {
  final requests = <http.Request>[];
  final tokenRequests = <http.Request>[];

  /// When set, the token endpoint rejects the client with this OAuth error.
  String? tokenError;

  /// When set, the token endpoint throws this instead of answering.
  Object? tokenThrows;

  late final http.Client client = MockClient((request) async {
    requests.add(request);
    if (request.url.path.endsWith('/token')) {
      tokenRequests.add(request);
      if (tokenThrows != null) throw tokenThrows!;
      if (tokenError != null) return _json({'error': tokenError}, 401);
      return _json({'access_token': 'sa-token-${tokenRequests.length}', 'token_type': 'Bearer', 'expires_in': 300});
    }
    if (request.url.path.endsWith('/userinfo')) {
      return _json({'sub': 'sa-1', 'preferred_username': 'service-account-backend'});
    }
    return http.Response('not found', 404);
  });
}

ClientConfig _saConfig({String? secret = 's3cret'}) => ClientConfig(
  baseUrl: 'http://localhost',
  realm: 'test',
  clientId: 'backend',
  clientSecret: secret,
  grantType: GrantType.clientCredentials,
);

/// A stored service-account token whose access token has already expired.
UserCredentials _expiredSaCreds() => UserCredentials(
  accessToken: 'sa-token-old',
  refreshToken: '',
  accessTokenExpiry: DateTime.now().subtract(const Duration(minutes: 1)),
  refreshTokenExpiry: DateTime(9999),
  isOfflineToken: true,
);
```

Add this group at the end of `main()`:

```dart
  group('service account mode', () {
    test('the constructor rejects a missing secret', () {
      for (final secret in [null, '']) {
        expect(
          () => KeycloakClient.withDependencies(clientConfig: _saConfig(secret: secret), credentialsStorage: FakeStore()),
          throwsArgumentError,
          reason: 'secret: $secret',
        );
      }
    });

    test('login() runs the client-credentials grant and never opens a browser', () async {
      final kc = FakeKeycloak();
      final probe = LoginProbe();
      final store = FakeStore();
      final client = KeycloakClient.withDependencies(
        clientConfig: _saConfig(),
        credentialsStorage: store,
        desktopLoginStrategy: SlowDesktopStrategy(probe),
        mobileLoginStrategy: SlowMobileStrategy(probe),
        httpClient: kc.client,
      );

      await client.login();

      expect(probe.calls, 0, reason: 'a browser login strategy was used');
      expect(kc.tokenRequests, hasLength(1));
      final grant = kc.tokenRequests.single;
      expect(grant.bodyFields['grant_type'], 'client_credentials');
      expect(grant.headers['authorization'], 'Basic ${base64Encode(utf8.encode('backend:s3cret'))}');
      expect(client.authState, AuthState.signedIn);
      expect(client.currentUser?.username, 'service-account-backend');
      expect(await client.getAuthToken(), 'sa-token-1');
      // No refresh token, so no local expiry: initialize() must never call a
      // service-account session expired.
      expect(store.creds!.isOfflineToken, isTrue);
      expect(store.creds!.isRefreshExpired, isFalse);

      client.dispose();
    });

    test('an expired token is renewed with a new grant', () async {
      final kc = FakeKeycloak();
      final store = FakeStore();
      final client = KeycloakClient.withDependencies(
        clientConfig: _saConfig(),
        credentialsStorage: store,
        httpClient: kc.client,
      );
      await client.login();

      store.creds = _expiredSaCreds();
      final token = await client.getAuthToken();

      expect(token, 'sa-token-2');
      expect(kc.tokenRequests, hasLength(2));
      expect(kc.tokenRequests.last.bodyFields['grant_type'], 'client_credentials');

      client.dispose();
    });

    test('initialize() restores a stored session and renews its expired token', () async {
      final kc = FakeKeycloak();
      final store = FakeStore(creds: _expiredSaCreds(), user: const UserInfo(id: 'sa-1'));
      final client = KeycloakClient.withDependencies(
        clientConfig: _saConfig(),
        credentialsStorage: store,
        httpClient: kc.client,
      );

      await client.waitForInitialization();

      expect(client.authState, AuthState.signedIn);
      expect(kc.tokenRequests, hasLength(1));
      expect(store.creds!.accessToken, 'sa-token-1');

      client.dispose();
    });

    test('a rejected secret during renewal ends the session without retrying', () async {
      final kc = FakeKeycloak();
      final store = FakeStore();
      final client = KeycloakClient.withDependencies(
        clientConfig: _saConfig(),
        credentialsStorage: store,
        httpClient: kc.client,
      );
      await client.login();

      kc.tokenError = 'invalid_client';
      store.creds = _expiredSaCreds();
      final token = await client.getAuthToken();
      await Future.delayed(const Duration(milliseconds: 100));

      expect(token, isNull);
      expect(client.authState, AuthState.sessionExpired);
      expect(kc.tokenRequests, hasLength(2), reason: 'a retry was scheduled');

      client.dispose();
    });

    test('login() maps a rejected secret to KeycloakServerException', () async {
      final kc = FakeKeycloak()..tokenError = 'unauthorized_client';
      final client = KeycloakClient.withDependencies(
        clientConfig: _saConfig(),
        credentialsStorage: FakeStore(),
        httpClient: kc.client,
      );

      await expectLater(client.login(), throwsA(isA<KeycloakServerException>()));
      expect(client.authState, AuthState.signedOut);

      client.dispose();
    });

    test('login() maps a socket error to KeycloakNetworkException', () async {
      final kc = FakeKeycloak()..tokenThrows = const SocketException('unreachable');
      final client = KeycloakClient.withDependencies(
        clientConfig: _saConfig(),
        credentialsStorage: FakeStore(),
        httpClient: kc.client,
      );

      await expectLater(client.login(), throwsA(isA<KeycloakNetworkException>()));

      client.dispose();
    });
  });
```

- [ ] **Step 3: Run the tests and confirm they fail**

Run: `flutter test test/keycloak_client_test.dart`
Expected: compile error, `No named parameter with the name 'httpClient'`.

- [ ] **Step 4: Implement**

All edits below are in `lib/keycloak_client.dart`.

**4a. Imports.** Add these after `import 'dart:convert';`:

```dart
import 'dart:io';
```

Add these after `import 'package:flutter/foundation.dart';`:

```dart
import 'package:http/http.dart' as http;
```

**4b. Field.** Add after `final RefreshOperation? _tokenRefreshOperation;`:

```dart
  /// Transport for the client-credentials grant. Null in production, where
  /// each grant opens its own connection; tests inject a fake.
  final http.Client? _httpClient;
```

**4c. Constructors.** In the public `KeycloakClient(...)` initializer list, add `_httpClient = null,` after `_tokenRefreshOperation = null,`.

In `KeycloakClient.withDependencies`, add the parameter `http.Client? httpClient,` after `RefreshOperation? tokenRefreshOperation,`, and the initializer `_httpClient = httpClient,` after `_tokenRefreshOperation = tokenRefreshOperation,`.

**4d. `_createInternals()`.** Replace the method with:

```dart
  void _createInternals() {
    if (_clientConfig.isServiceAccount && (_clientConfig.clientSecret?.isEmpty ?? true)) {
      throw ArgumentError.value(
        _clientConfig.clientSecret,
        'clientConfig.clientSecret',
        'is required with GrantType.clientCredentials',
      );
    }
    _sessionManager = SessionManager();
    _tokenService = TokenService(
      store: _credentialsStorage,
      scopes: _clientConfig.scopes,
      onPermanentFailure: () => _endSession(AuthState.sessionExpired),
      onRecovery: () => _reloadUser().ignore(),
      onTokenRefreshed: _handleTokenRefreshed,
      logger: _logger,
      refreshTimeout: _clientConfig.refreshTimeout,
      refreshTokenLifetime: _clientConfig.refreshTokenLifetime,
      isOfflineSession: _noLocalRefreshExpiry,
      refreshOperation: _tokenRefreshOperation ?? (_clientConfig.isServiceAccount ? _renewServiceAccountToken : null),
      permanentAuthErrors: _clientConfig.isServiceAccount
          ? const {'invalid_grant', 'invalid_client', 'unauthorized_client'}
          : null,
    );
  }

  /// Offline tokens and service accounts both have no refresh-token expiry
  /// the client can know: an offline token's is server-side only, and a
  /// service account has no refresh token at all, only a secret that stays
  /// valid until it is rotated.
  bool get _noLocalRefreshExpiry => _clientConfig.isOfflineSession || _clientConfig.isServiceAccount;

  Future<Client> _clientCredentialsGrant() => clientCredentialsGrant(
    _clientConfig.tokenEndpoint,
    _clientConfig.clientId,
    _clientConfig.clientSecret,
    scopes: _clientConfig.scopes,
    httpClient: _httpClient,
  );

  /// The service-account "refresh": there is no refresh token, so a new grant
  /// replaces the old client, which is then closed to free its connection.
  Future<Client> _renewServiceAccountToken(Client current, List<String> _) async {
    final next = await _clientCredentialsGrant();
    current.close();
    return next;
  }

  /// Runs the client-credentials grant for [login], mapping failures onto the
  /// same exceptions the browser strategies throw.
  Future<Client> _serviceAccountLogin() async {
    try {
      return await _clientCredentialsGrant().timeout(_clientConfig.refreshTimeout);
    } on AuthorizationException catch (e) {
      throw KeycloakServerException(400, e.error);
    } on FormatException catch (e) {
      throw KeycloakServerException(400, e.message);
    } on SocketException catch (e) {
      throw KeycloakNetworkException(e);
    } on http.ClientException catch (e) {
      throw KeycloakNetworkException(e);
    } on TimeoutException {
      throw const KeycloakTimeoutException('Client-credentials grant timed out.');
    }
  }
```

**4e. `initialize()`.** Pass the transport to the restored client so that renewals and userinfo calls use it. Replace:

```dart
          _tokenService.setClient(Client(stored.toOAuth2Credentials(_clientConfig.tokenEndpoint), identifier: _clientConfig.clientId));
```

with:

```dart
          _tokenService.setClient(
            Client(stored.toOAuth2Credentials(_clientConfig.tokenEndpoint), identifier: _clientConfig.clientId, httpClient: _httpClient),
          );
```

**4f. `_login()`.** Replace the `final client = await switch (...)` statement with:

```dart
    final client = _clientConfig.isServiceAccount
        ? await _serviceAccountLogin()
        : await switch (_loginStrategy) {
            final IDesktopLoginStrategy strategy => strategy.login(platformConfig: _desktopConfig, clientConfig: _clientConfig),
            final IMobileLoginStrategy strategy => strategy.login(platformConfig: _mobileConfig, clientConfig: _clientConfig),
            final IWebLoginStrategy strategy => strategy.login(platformConfig: _webConfig, clientConfig: _clientConfig),
            _ => throw StateError('Unknown login strategy type: ${_loginStrategy.runtimeType}'),
          };
```

Also change the log line above it to:

```dart
    _logger.info(_clientConfig.isServiceAccount
        ? 'Initiating client-credentials grant.'
        : 'Initiating login flow via ${_loginStrategy.runtimeType}.');
```

**4g. `_finalizeLogin()`.** Replace `isOfflineToken: _clientConfig.isOfflineSession,` with:

```dart
      isOfflineToken: _noLocalRefreshExpiry,
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `flutter test test/keycloak_client_test.dart`
Expected: all pass, the original 9 plus 7 new ones.

- [ ] **Step 6: Run the whole unit suite**

Run: `flutter test test/keycloak_client_test.dart test/src`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/keycloak_client.dart test/keycloak_client_test.dart
git commit -m "feat: service-account login via the client-credentials grant"
```

---

### Task 4: `logout()` and the user-only methods

**Files:**
- Modify: `lib/keycloak_client.dart` (`getAccountCredentials`, `manageAccount`, `handleWebCallback`, `logout`)
- Test: `test/keycloak_client_test.dart` (the `service account mode` group)

- [ ] **Step 1: Write the failing tests**

Add these to the `service account mode` group:

```dart
    test('logout() clears the session without calling the server', () async {
      final kc = FakeKeycloak();
      final store = FakeStore();
      final client = KeycloakClient.withDependencies(
        clientConfig: _saConfig(),
        credentialsStorage: store,
        httpClient: kc.client,
      );
      await client.login();
      final before = kc.requests.length;

      await client.logout();

      expect(kc.requests, hasLength(before), reason: 'logout contacted Keycloak');
      expect(client.authState, AuthState.signedOut);
      expect(store.creds, isNull);

      client.dispose();
    });

    test('user-only methods throw UnsupportedError', () async {
      final client = KeycloakClient.withDependencies(
        clientConfig: _saConfig(),
        credentialsStorage: FakeStore(),
        httpClient: FakeKeycloak().client,
      );

      await expectLater(client.manageAccount(), throwsUnsupportedError);
      await expectLater(client.getAccountCredentials(), throwsUnsupportedError);
      await expectLater(client.handleWebCallback(Uri.parse('http://localhost/cb')), throwsUnsupportedError);

      client.dispose();
    });
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `flutter test test/keycloak_client_test.dart --plain-name "service account mode"`
Expected: 2 failures. `logout` posts to `/logout`. `handleWebCallback` throws `StateError`. The other two throw something other than `UnsupportedError`.

- [ ] **Step 3: Implement**

Add this helper next to `_assertNotDisposed()`:

```dart
  void _assertUserFlow(String method) {
    if (_clientConfig.isServiceAccount) {
      throw UnsupportedError('$method is not available with GrantType.clientCredentials.');
    }
  }
```

Make it the first statement of each of these methods:
- `getAccountCredentials()`: `_assertUserFlow('getAccountCredentials()');`, placed before `await waitForInitialization();`
- `manageAccount()`: `_assertUserFlow('manageAccount()');`, placed after `_assertNotDisposed();`
- `handleWebCallback()`: `_assertUserFlow('handleWebCallback()');`, placed before the `IWebLoginStrategy` check

In `logout()`, change `if (stored != null) {` to:

```dart
    // A service account has no refresh token and no browser session to end.
    if (stored != null && !_clientConfig.isServiceAccount) {
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `flutter test test/keycloak_client_test.dart test/src`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/keycloak_client.dart test/keycloak_client_test.dart
git commit -m "feat: service-account logout and unsupported user-only methods"
```

---

### Task 5: Live test against a real Keycloak

**Files:**
- Modify: `test/live/keycloak_live_test.dart` (header comment and one new `liveTest`)

- [ ] **Step 1: Add the test**

Extend the setup paragraph in the header comment with:

```dart
// For the service-account test, also create confidential client
// `backend-sa` with Client authentication ON, Service accounts roles ON, and
// client secret `backend-sa-secret`.
```

Add this at the end of `main()`:

```dart
  liveTest('a service account signs in with the client-credentials grant', () async {
    final client = KeycloakClient.withDependencies(
      clientConfig: const ClientConfig(
        baseUrl: _baseUrl,
        realm: _realm,
        clientId: 'backend-sa',
        clientSecret: 'backend-sa-secret',
        grantType: GrantType.clientCredentials,
      ),
      credentialsStorage: MemoryStore(),
    );

    await client.login();

    expect(client.authState, AuthState.signedIn);
    expect(client.currentUser?.username, 'service-account-backend-sa');
    expect(await client.getAuthToken(), isNotEmpty);

    await client.refreshToken(); // a second grant over the wire
    expect(client.authState, AuthState.signedIn);
    print('  [ok] service account ${client.currentUser?.username}');

    client.dispose();
  });
```

- [ ] **Step 2: Run it**

Run: `flutter test test/live/keycloak_live_test.dart --plain-name "service account"`
Expected: passes when the Keycloak container and the `backend-sa` client exist. Otherwise it's reported as skipped. Record which one happened; don't claim a pass if it was skipped.

- [ ] **Step 3: Commit**

```bash
git add test/live/keycloak_live_test.dart
git commit -m "test: service-account login against a real Keycloak"
```

---

### Task 6: Documentation and version

**Files:**
- Modify: `README.md` (the `ClientConfig` fields list, a new section before `## Dev Redirect Helper`, and `## Keycloak`)
- Modify: `CHANGELOG.md`
- Modify: `pubspec.yaml` (`version:`)

- [ ] **Step 1: README field list**

In the `ClientConfig` fields list, change the `clientSecret` bullet and add a `grantType` bullet after `refreshTimeout`:

```markdown
- `clientSecret`: for confidential clients; required with `GrantType.clientCredentials`
- `grantType`: `GrantType.authorizationCode` (default, browser login) or `GrantType.clientCredentials` (service account, see below)
```

- [ ] **Step 2: README section**

Insert this before `## Dev Redirect Helper`:

````markdown
## Service Accounts

To authenticate as the client's own Keycloak service account instead of a
user, set `grantType`:

```dart
final client = KeycloakClient(
  clientConfig: ClientConfig(
    baseUrl: 'https://auth.example.com',
    realm: 'my-realm',
    clientId: 'my-backend',
    clientSecret: '...',
    grantType: GrantType.clientCredentials,
  ),
);

await client.login();                      // no browser
final token = await client.getAuthToken(); // renewed automatically
```

In Keycloak, turn on **Client authentication** and **Service accounts roles**
for the client.

- `login()` fetches a token with the client ID and secret. When the token
  expires, a new one is fetched the same way; there is no refresh token.
- `currentUser` is Keycloak's `service-account-<clientId>` user.
- `logout()` only clears the local session.
- `manageAccount()`, `getAccountCredentials()` and `handleWebCallback()`
  throw `UnsupportedError`.
- If Keycloak rejects the secret during renewal, the session ends as
  `AuthState.sessionExpired`.

> **Never ship a client secret in a public mobile, web or desktop build.**
> Anyone can extract it. Use this mode only on machines you control.
````

- [ ] **Step 3: CHANGELOG and version**

Add this at the top of `CHANGELOG.md`, under `# CHANGELOG`:

```markdown
## 4.0.0

### New

- Service-account mode: `ClientConfig.grantType: GrantType.clientCredentials`
  makes `login()` use the OAuth2 client-credentials grant with `clientId` and
  `clientSecret`, with no browser. Expired tokens are renewed with a new grant.
  `invalid_client` / `unauthorized_client` during renewal end the session
  instead of retrying forever. `manageAccount()`, `getAccountCredentials()` and
  `handleWebCallback()` throw `UnsupportedError` in this mode. The default,
  `GrantType.authorizationCode`, leaves existing behaviour unchanged.
- `package:http` is now a direct dependency (it already came in through
  `oauth2`).
```

In `pubspec.yaml`, change `version: 3.0.0` to `version: 4.0.0`. This release also carries the required-roles work (`2026-09-18-required-roles.md`), which adds to this same CHANGELOG entry. There is no separate 3.x release.

- [ ] **Step 4: Analyze and run the full suite**

Run: `flutter analyze && flutter test test/keycloak_client_test.dart test/src`
Expected: `No issues found!`, and all tests pass.

- [ ] **Step 5: Commit**

```bash
git add README.md CHANGELOG.md pubspec.yaml
git commit -m "docs: service-account mode (4.0.0)"
```
