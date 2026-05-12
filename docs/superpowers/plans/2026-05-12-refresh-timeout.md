# Refresh Timeout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent `TokenService._doRefresh()` from hanging indefinitely when the network is connected but unresponsive, by adding a configurable timeout that routes to the existing transient-failure path.

**Architecture:** Add `refreshTimeout` to `ClientConfig` (user-facing) and `TokenService` (internal). Apply `.timeout()` to the `_refreshOperation` call in `_doRefresh()`. Catch the resulting `TimeoutException` (same `dart:async` that is already imported) and route it through the existing `_handleTransientFailure()` — no new retry logic needed. The injectable `refreshOperation` already in place makes this testable without `fakeAsync`.

**Tech Stack:** Dart 3, `dart:async` (`TimeoutException`), `flutter_test`, `mocktail`

---

## File Map

| Action | Path | Change |
|---|---|---|
| Modify | `lib/src/models/client_config.dart` | Add `refreshTimeout` field with 15s default |
| Modify | `lib/src/core/token_service.dart` | Add `refreshTimeout` constructor param, apply `.timeout()`, catch `TimeoutException` |
| Modify | `lib/keycloak_client.dart` | Pass `_clientConfig.refreshTimeout` to `TokenService` in `_createInternals()` |
| Modify | `test/src/core/token_service_test.dart` | Update `_makeService` helper, add 2 timeout tests |

---

## Task 1: Add `refreshTimeout` to `ClientConfig` and wire through `KeycloakClient`

**Files:**
- Modify: `lib/src/models/client_config.dart`
- Modify: `lib/keycloak_client.dart`

- [ ] **Step 1: Add `refreshTimeout` to `ClientConfig`**

In `lib/src/models/client_config.dart`, add the field and constructor parameter:

```dart
final class ClientConfig {
  final String baseUrl;
  final String realm;
  final String clientId;
  final String? clientSecret;
  final List<String> scopes;
  final LogLevel logLevel;
  final DesktopConfig desktop;
  final MobileConfig mobile;
  final WebConfig web;

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
    this.logLevel = LogLevel.trace,
    this.desktop = const DesktopConfig(),
    this.mobile = const MobileConfig(),
    this.web = const WebConfig(),
    this.refreshTimeout = const Duration(seconds: 15),
  });

  Uri get authorizationEndpoint => Uri.parse('$baseUrl/realms/$realm/protocol/openid-connect/auth');
  Uri get tokenEndpoint => Uri.parse('$baseUrl/realms/$realm/protocol/openid-connect/token');
  Uri get userInfoEndpoint => Uri.parse('$baseUrl/realms/$realm/protocol/openid-connect/userinfo');
  Uri get logoutEndpoint => Uri.parse('$baseUrl/realms/$realm/protocol/openid-connect/logout');
  Uri get accountEndpoint => Uri.parse('$baseUrl/realms/$realm/account');
}
```

- [ ] **Step 2: Wire `refreshTimeout` through `_createInternals()` in `KeycloakClient`**

In `lib/keycloak_client.dart`, find the `_createInternals()` method and add `refreshTimeout` to the `TokenService` constructor call:

```dart
void _createInternals() {
  _sessionManager = SessionManager();
  _tokenService = TokenService(
    store: _credentialsStorage,
    scopes: _scopes,
    onPermanentFailure: () => _endSession(AuthState.sessionExpired),
    onRecovery: () => _reloadUser().ignore(),
    logger: _logger,
    refreshTimeout: _clientConfig.refreshTimeout,
  );
}
```

- [ ] **Step 3: Run analyze to confirm no issues**

```
cd "c:\Users\Ehsan Rashidi\Desktop\Winche\Dart\keycloak_client" && flutter analyze lib/
```

Expected: No issues. (`TokenService` does not yet accept `refreshTimeout` so this will fail — this step intentionally verifies the wiring is in place before Task 2 makes it compile.)

> Note: the analyze step will produce one error (`refreshTimeout` not a named parameter on `TokenService` yet). That is expected — Task 2 adds the receiving side. If you want to run tests between tasks, skip this step and continue to Task 2.

---

## Task 2: Apply timeout in `TokenService` and test it

**Files:**
- Modify: `lib/src/core/token_service.dart`
- Modify: `test/src/core/token_service_test.dart`

- [ ] **Step 1: Write the failing tests**

In `test/src/core/token_service_test.dart`:

**2a. Update `_makeService` to accept an optional `refreshTimeout`**

Find the `_makeService` helper and add a `refreshTimeout` parameter:

```dart
TokenService _makeService(
  Future<oauth2.Client> Function(oauth2.Client, List<String>) refreshOp, {
  Duration refreshTimeout = const Duration(seconds: 30),
}) {
  return TokenService(
    store: store,
    scopes: const ['openid'],
    onPermanentFailure: () async => permanentCalls++,
    onRecovery: () => recoveryCalls++,
    logger: logger,
    refreshOperation: refreshOp,
    refreshTimeout: refreshTimeout,
  );
}
```

**2b. Add a `'timeout'` group with two tests** (append inside `main()`):

```dart
group('timeout', () {
  test('hanging refresh returns RefreshTransientFailure', () async {
    when(() => store.getCredentials()).thenAnswer((_) async => _validCreds());

    final service = _makeService(
      (_, __) => Completer<oauth2.Client>().future, // never resolves
      refreshTimeout: const Duration(milliseconds: 10),
    );
    service.setClient(oauthClient);

    final result = await service.attemptRefresh();

    expect(result, isA<RefreshTransientFailure>());
    expect(permanentCalls, 0);
    service.dispose();
  });

  test('hanging refresh with locally expired refresh token ends session', () async {
    when(() => store.getCredentials())
        .thenAnswer((_) async => _expiredRefreshCreds());

    final service = _makeService(
      (_, __) => Completer<oauth2.Client>().future,
      refreshTimeout: const Duration(milliseconds: 10),
    );
    service.setClient(oauthClient);

    final result = await service.attemptRefresh();

    expect(result, isA<RefreshPermanentFailure>());
    expect(permanentCalls, 1);
    service.dispose();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```
cd "c:\Users\Ehsan Rashidi\Desktop\Winche\Dart\keycloak_client" && flutter test test/src/core/token_service_test.dart -v
```

Expected: FAIL — `refreshTimeout` is not a named parameter on `TokenService` yet.

- [ ] **Step 3: Add `refreshTimeout` to `TokenService`, apply `.timeout()`, catch `TimeoutException`**

In `lib/src/core/token_service.dart`:

**3a. Add the field:**

```dart
final Duration _refreshTimeout;
```

Place it alongside the other `final` fields (`_store`, `_scopes`, `_logger`, `_refreshOperation`).

**3b. Add the constructor parameter and initializer:**

```dart
TokenService({
  required IAuthCredentialsStore store,
  required List<String> scopes,
  required this.onPermanentFailure,
  required this.onRecovery,
  required Logger logger,
  Duration refreshTimeout = const Duration(seconds: 15),
  @visibleForTesting RefreshOperation? refreshOperation,
})  : _store = store,
      _scopes = scopes,
      _logger = logger,
      _refreshTimeout = refreshTimeout,
      _refreshOperation =
          refreshOperation ?? ((client, scopes) => client.refreshCredentials(scopes));
```

**3c. Apply `.timeout()` to the `_refreshOperation` call in `_doRefresh()`:**

Find this line in `_doRefresh()`:
```dart
_oauthClient = await _refreshOperation(_oauthClient!, _scopes);
```

Replace it with:
```dart
_oauthClient = await _refreshOperation(_oauthClient!, _scopes)
    .timeout(_refreshTimeout);
```

**3d. Add a `TimeoutException` catch clause in `_doRefresh()`:**

`TimeoutException` is in `dart:async`, which is already imported. Add the catch after the `SocketException` catch:

```dart
} on SocketException catch (e, st) {
  _logger.w('Network error during refresh, retrying in 30s.',
      error: e, stackTrace: st);
  return _handleTransientFailure(e);
} on TimeoutException catch (e, st) {
  _logger.w('Token refresh timed out, retrying in 30s.',
      error: e, stackTrace: st);
  return _handleTransientFailure(e);
}
```

The complete `_doRefresh()` exception-handling section after this change:

```dart
} on oauth2.ExpirationException {
  _logger.w('Session expired, re-authentication required.');
  await onPermanentFailure();
  return const RefreshPermanentFailure();
} on oauth2.AuthorizationException catch (e, st) {
  if (e.error == 'invalid_grant') {
    _logger.w('Refresh token revoked or expired (invalid_grant).');
    await onPermanentFailure();
    return const RefreshPermanentFailure();
  }
  _logger.e('Authorization error during refresh, retrying in 30s.',
      error: e, stackTrace: st);
  return _handleTransientFailure(e);
} on SocketException catch (e, st) {
  _logger.w('Network error during refresh, retrying in 30s.',
      error: e, stackTrace: st);
  return _handleTransientFailure(e);
} on TimeoutException catch (e, st) {
  _logger.w('Token refresh timed out, retrying in 30s.',
      error: e, stackTrace: st);
  return _handleTransientFailure(e);
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
cd "c:\Users\Ehsan Rashidi\Desktop\Winche\Dart\keycloak_client" && flutter test test/src/core/token_service_test.dart -v
```

Expected: 14 tests pass (12 existing + 2 new timeout tests).

- [ ] **Step 5: Run full suite + analyze**

```
cd "c:\Users\Ehsan Rashidi\Desktop\Winche\Dart\keycloak_client" && flutter test -v && flutter analyze lib/
```

Expected: 29 tests pass (27 existing + 2 new), no analyzer issues.
