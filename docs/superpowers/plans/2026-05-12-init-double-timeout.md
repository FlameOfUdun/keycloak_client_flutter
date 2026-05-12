# Init Double-Timeout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent `initialize()` from calling `attemptRefresh()` twice when the access token is expired and the server is unreachable, cutting worst-case offline init time from ~30 s to ~15 s.

**Architecture:** In `initialize()`, `_reloadUser().ignore()` is currently unconditional after the access-expired branch. When refresh returns `RefreshTransientFailure`, skip the `_reloadUser()` call entirely — the existing `onRecovery` callback already fires `_reloadUser().ignore()` the moment the network recovers. To make this testable, expose an optional `@visibleForTesting RefreshOperation? tokenRefreshOperation` on `KeycloakClient.withDependencies` and thread it through to `TokenService`.

**Tech Stack:** Dart 3, `flutter_test`, `mocktail`

---

## File Map

| Action | Path | Change |
|---|---|---|
| Modify | `lib/keycloak_client.dart` | Add `_tokenRefreshOperation` field; add param to `withDependencies`; pass to `TokenService`; fix `initialize()` conditional |
| Create | `test/keycloak_client_test.dart` | Integration test: expired access token + offline → `refreshOperation` called exactly once |

---

## Task 1: Wire `tokenRefreshOperation` injection into `KeycloakClient`

**Files:**
- Modify: `lib/keycloak_client.dart`

- [ ] **Step 1: Add the `_tokenRefreshOperation` field**

In `lib/keycloak_client.dart`, add one field alongside the other `late final` fields (before `_clientConfig`):

```dart
final class KeycloakClient {
  late final IAuthCredentialsStore _credentialsStorage;
  late final ILoginStrategy _loginStrategy;
  late final Logger _logger;
  late final SessionManager _sessionManager;
  late final TokenService _tokenService;

  final ClientConfig _clientConfig;
  final RefreshOperation? _tokenRefreshOperation; // ← ADD THIS
```

The field is nullable because only tests supply it; production leaves it null.

- [ ] **Step 2: Add the parameter to `withDependencies` and initialise the field**

Find the `withDependencies` constructor:

```dart
@visibleForTesting
KeycloakClient.withDependencies({
  required ClientConfig config,
  required IAuthCredentialsStore credentialsStorage,
  IDesktopLoginStrategy? desktopLoginStrategy,
  IMobileLoginStrategy? mobileLoginStrategy,
  IWebLoginStrategy? webLoginStrategy,
}) : _clientConfig = config,
     _credentialsStorage = credentialsStorage,
     ...
```

Replace it with:

```dart
@visibleForTesting
KeycloakClient.withDependencies({
  required ClientConfig config,
  required IAuthCredentialsStore credentialsStorage,
  IDesktopLoginStrategy? desktopLoginStrategy,
  IMobileLoginStrategy? mobileLoginStrategy,
  IWebLoginStrategy? webLoginStrategy,
  @visibleForTesting RefreshOperation? tokenRefreshOperation,
}) : _clientConfig = config,
     _credentialsStorage = credentialsStorage,
     _tokenRefreshOperation = tokenRefreshOperation,
     _loginStrategy = _selectLoginStrategy(
       desktopOverride: desktopLoginStrategy,
       mobileOverride: mobileLoginStrategy,
       webOverride: webLoginStrategy,
     ) {
  _createLogger(config.logLevel);
  _createInternals();
}
```

Also update the default constructor to initialise the field as null. Find:

```dart
KeycloakClient({required ClientConfig config})
    : _clientConfig = config,
      _credentialsStorage = const SecureStorageAuthCredentialsStore(),
      _loginStrategy = defaultLoginStrategy {
```

Replace with:

```dart
KeycloakClient({required ClientConfig config})
    : _clientConfig = config,
      _credentialsStorage = const SecureStorageAuthCredentialsStore(),
      _tokenRefreshOperation = null,
      _loginStrategy = defaultLoginStrategy {
```

- [ ] **Step 3: Pass `_tokenRefreshOperation` to `TokenService` in `_createInternals()`**

Find:

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

Replace with:

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
    refreshOperation: _tokenRefreshOperation,
  );
}
```

- [ ] **Step 4: Run analyze to confirm no issues**

```
cd "c:\Users\Ehsan Rashidi\Desktop\Winche\Dart\keycloak_client" && flutter analyze lib/
```

Expected: No issues.

---

## Task 2: Fix `initialize()` — skip `_reloadUser()` on transient failure

**Files:**
- Modify: `lib/keycloak_client.dart`
- Create: `test/keycloak_client_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/keycloak_client_test.dart`:

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:keycloak_client/keycloak_client.dart';
import 'package:keycloak_client/src/interfaces/auth_credentials_store.dart';
import 'package:keycloak_client/src/models/user_credentials.dart';

class MockStore extends Mock implements IAuthCredentialsStore {}

void main() {
  late MockStore store;

  setUpAll(() {
    registerFallbackValue(
      UserCredentials(
        accessToken: 'a',
        refreshToken: 'r',
        accessTokenExpiry: DateTime.now().add(const Duration(minutes: 5)),
        refreshTokenExpiry: DateTime.now().add(const Duration(days: 30)),
      ),
    );
  });

  setUp(() {
    store = MockStore();
  });

  group('initialize()', () {
    test(
        'calls refreshOperation exactly once when access token is expired and '
        'server is offline', () async {
      // Credentials: access expired, refresh still valid
      final storedCreds = UserCredentials(
        accessToken: 'old-access',
        refreshToken: 'valid-refresh',
        accessTokenExpiry: DateTime.now().subtract(const Duration(hours: 1)),
        refreshTokenExpiry: DateTime.now().add(const Duration(days: 30)),
      );
      final storedUser = const UserInfo(id: 'u1');

      when(() => store.getCredentials()).thenAnswer((_) async => storedCreds);
      when(() => store.getUser()).thenAnswer((_) async => storedUser);
      when(() => store.setCredentials(any())).thenAnswer((_) async {});

      var refreshCallCount = 0;

      final client = KeycloakClient.withDependencies(
        config: ClientConfig(
          baseUrl: 'http://localhost',
          realm: 'test',
          clientId: 'app',
          refreshTimeout: const Duration(milliseconds: 100),
        ),
        credentialsStorage: store,
        tokenRefreshOperation: (_, __) {
          refreshCallCount++;
          return Completer<oauth2.Client>().future; // never resolves → timeout
        },
      );

      await client.waitForInitialization();

      expect(refreshCallCount, 1,
          reason: 'Double-timeout bug: refreshOperation called more than once during initialize()');

      client.dispose();
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```
cd "c:\Users\Ehsan Rashidi\Desktop\Winche\Dart\keycloak_client" && flutter test test/keycloak_client_test.dart -v
```

Expected: FAIL — `refreshCallCount` equals 2 (the bug), not 1.

- [ ] **Step 3: Fix `initialize()` in `lib/keycloak_client.dart`**

Find this block inside `initialize()` (around line 198–223):

```dart
      if (stored.isAccessExpired) {
        _logger.i('Access token expired, refreshing on init.');
        final result = await _tokenService.attemptRefresh();
        if (result is RefreshPermanentFailure) return;
        _sessionManager.beginSession(user);
      } else {
        _sessionManager.beginSession(user);
        _tokenService.scheduleRefresh(stored);
      }

      _reloadUser().ignore();
```

Replace it with:

```dart
      if (stored.isAccessExpired) {
        _logger.i('Access token expired, refreshing on init.');
        final result = await _tokenService.attemptRefresh();
        if (result is RefreshPermanentFailure) return;
        _sessionManager.beginSession(user);
        // Only re-fetch user info when refresh actually succeeded.
        // On transient failure onRecovery fires _reloadUser() when network returns.
        if (result is RefreshSuccess) _reloadUser().ignore();
      } else {
        _sessionManager.beginSession(user);
        _tokenService.scheduleRefresh(stored);
        _reloadUser().ignore();
      }
```

- [ ] **Step 4: Run tests to verify they pass**

```
cd "c:\Users\Ehsan Rashidi\Desktop\Winche\Dart\keycloak_client" && flutter test test/keycloak_client_test.dart -v
```

Expected: PASS — `refreshCallCount` equals 1.

- [ ] **Step 5: Run full suite + analyze**

```
cd "c:\Users\Ehsan Rashidi\Desktop\Winche\Dart\keycloak_client" && flutter test -v && flutter analyze lib/
```

Expected: all tests pass, no analyzer issues.
