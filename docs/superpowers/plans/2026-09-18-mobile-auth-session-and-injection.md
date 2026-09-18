# Mobile Auth Session and Public Injection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve GitHub issue #2. Mobile login moves to an in-app auth session through `flutter_web_auth_2`, and consumers get a public way to inject a login strategy and credentials store, with the default store and the PKCE helpers exported.

**Architecture:**
- **Exports:** two new export lines.
- **Constructor:** the public `KeycloakClient(...)` gains the optional injection parameters that `withDependencies` already routes through `_selectLoginStrategy`.
- **Strategy:** `MobileLoginStrategy` keeps PKCE, `state` and the code exchange, but gets the callback URL from `FlutterWebAuth2.authenticate` instead of `url_launcher` plus `app_links`. The authenticator is injectable for tests.
- **Config:** `MobileConfig` swaps `deepLinkTimeout` for `preferEphemeral`, which defaults to `true`.

**Tech Stack:** Dart 3 / Flutter ≥3.24, `flutter_web_auth_2` ^5.1.0, `package:oauth2`, `package:http/testing.dart`, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-09-18-mobile-auth-session-and-injection-design.md`

**Prerequisite:** the service-account and required-roles plans are implemented on `feat/v4`, and so are the final-review fixes. This plan adds to the same 4.0.0 release.

**Verification baseline:** run `flutter test test/keycloak_client_test.dart test/src` for the current count. `flutter analyze` reports 23 existing infos in test files; add no new ones. If a run changes `example/pubspec.lock`, revert it with `git checkout -- example/pubspec.lock`, except in Task 3, where the dependency change legitimately updates it.

---

## File map

| File | Change |
|---|---|
| `lib/keycloak_client.dart` | Export the store and the PKCE helpers; optional injection parameters on the public constructor; `credentialsStorage` optional in `withDependencies`. |
| `lib/src/utilities/pkce.dart` | Doc touch-up (now public API). |
| `lib/src/models/platform_config.dart` | `MobileConfig`: remove `deepLinkTimeout`, add `preferEphemeral`. |
| `lib/src/strategies/mobile_login_strategy.dart` | Rewritten around `flutter_web_auth_2`. |
| `pubspec.yaml` | Add `flutter_web_auth_2`, remove `app_links`, set Flutter `>=3.24.0`. |
| `example/android/app/src/main/AndroidManifest.xml`, `example/ios/Runner/Info.plist` | New setup. |
| `test/public_api_test.dart` | **Create.** |
| `test/src/strategies/mobile_login_strategy_test.dart` | **Create.** |
| `test/keycloak_client_test.dart` | A `public constructor` group. |
| `README.md`, `CHANGELOG.md` | Docs under 4.0.0. |

---

### Task 1: Export the default store and the PKCE helpers

**Files:**
- Modify: `lib/keycloak_client.dart` (export block)
- Modify: `lib/src/utilities/pkce.dart` (doc comment)
- Test: `test/public_api_test.dart` (create)

- [ ] **Step 1: Write the failing test**

Create `test/public_api_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:keycloak_client/keycloak_client.dart';

void main() {
  test('the default credentials store is exported', () {
    // A consumer overriding the login strategy must not have to re-implement
    // storage (and its key names) just to fill the credentialsStorage slot.
    const IAuthCredentialsStore store = SecureStorageAuthCredentialsStore();
    expect(store, isA<SecureStorageAuthCredentialsStore>());
  });

  test('the PKCE helpers are exported', () {
    final verifier = generateCodeVerifier();

    expect(verifier, hasLength(64));
    expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(verifier), isTrue);
    expect(generateCodeVerifier(), isNot(verifier));
    expect(generateState(), matches(RegExp(r'^[0-9a-f]{32}$')));
  });
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `flutter test test/public_api_test.dart`
Expected: compile errors, `Undefined name 'SecureStorageAuthCredentialsStore'` and `generateCodeVerifier`.

- [ ] **Step 3: Implement**

In `lib/keycloak_client.dart`, add these after `export 'src/models/pending_grant.dart';`:

```dart
// The default store, so a consumer replacing one dependency is not forced to
// re-implement this one (and its storage keys) as well.
export 'src/utilities/secure_storage_auth_credentials_store.dart';
// For custom login strategies, so verifier and state generation keep a
// single definition.
export 'src/utilities/pkce.dart';
```

In `lib/src/utilities/pkce.dart`, add this library doc comment above `import 'dart:math';`:

```dart
/// PKCE and `state` generation for Authorization Code flows.
///
/// Exported for custom `ILoginStrategy` implementations, so they generate the
/// verifier and state exactly as the built-in strategies do.
library;
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `flutter test test/public_api_test.dart`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/keycloak_client.dart lib/src/utilities/pkce.dart test/public_api_test.dart
git commit -m "feat: export the default credentials store and PKCE helpers"
```

---

### Task 2: Injection through the public constructor

**Files:**
- Modify: `lib/keycloak_client.dart` (both constructors)
- Test: `test/keycloak_client_test.dart`

- [ ] **Step 1: Write the failing tests**

Add this group at the end of `main()` in `test/keycloak_client_test.dart`. It reuses the existing `LoginProbe`, `SlowMobileStrategy`, `SlowDesktopStrategy`, `FakeStore` and `_creds` helpers.

```dart
  group('public constructor', () {
    test('uses an injected login strategy and credentials store', () async {
      final probe = LoginProbe()..completer.complete(null); // user cancels
      final client = KeycloakClient(
        clientConfig: const ClientConfig(baseUrl: 'http://localhost', realm: 'test', clientId: 'app'),
        credentialsStorage: FakeStore(),
        // flutter_test pins the platform to android, so the mobile one is used.
        mobileLoginStrategy: SlowMobileStrategy(probe),
        desktopLoginStrategy: SlowDesktopStrategy(probe),
      );

      await client.login();

      expect(probe.calls, 1, reason: 'the injected strategy was not used');
      client.dispose();
    });

    test('restores a session from an injected store', () async {
      final client = KeycloakClient(
        clientConfig: const ClientConfig(baseUrl: 'http://localhost', realm: 'test', clientId: 'app'),
        credentialsStorage: FakeStore(creds: _creds(accessExpired: false), user: const UserInfo(id: 'u1')),
      );

      await client.waitForInitialization();

      expect(client.authState, AuthState.signedIn);
      expect(client.currentUser?.id, 'u1');
      client.dispose();
    });
  });
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `flutter test test/keycloak_client_test.dart --plain-name "public constructor"`
Expected: compile error, `No named parameter with the name 'credentialsStorage'`.

- [ ] **Step 3: Implement**

In `lib/keycloak_client.dart`, replace the public constructor, meaning its doc comment through the closing `}` of `_createInternals();`, with:

```dart
  /// Creates a [KeycloakClient].
  ///
  /// [credentialsStorage] defaults to [SecureStorageAuthCredentialsStore]. The
  /// login strategies default to the built-in one for each platform; only the
  /// one for the platform the app runs on is used, so an app can pass just
  /// the one it replaces.
  KeycloakClient({
    required ClientConfig clientConfig,
    WebConfig? webConfig,
    MobileConfig? mobileConfig,
    DesktopConfig? desktopConfig,
    IAuthCredentialsStore? credentialsStorage,
    IMobileLoginStrategy? mobileLoginStrategy,
    IDesktopLoginStrategy? desktopLoginStrategy,
    IWebLoginStrategy? webLoginStrategy,
  }) : _clientConfig = clientConfig,
       _desktopConfig = desktopConfig ?? const DesktopConfig(),
       _mobileConfig = mobileConfig ?? const MobileConfig(),
       _webConfig = webConfig ?? const WebConfig(),
       _credentialsStorage = credentialsStorage ?? const SecureStorageAuthCredentialsStore(),
       _tokenRefreshOperation = null,
       _httpClient = null,
       _loginStrategy = _selectLoginStrategy(
         desktopOverride: desktopLoginStrategy,
         mobileOverride: mobileLoginStrategy,
         webOverride: webLoginStrategy,
       ) {
    _createInternals();
  }
```

In `KeycloakClient.withDependencies`, change `required IAuthCredentialsStore credentialsStorage,` to `IAuthCredentialsStore? credentialsStorage,`, and change `_credentialsStorage = credentialsStorage,` to:

```dart
       _credentialsStorage = credentialsStorage ?? const SecureStorageAuthCredentialsStore(),
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `flutter test test/keycloak_client_test.dart test/src test/public_api_test.dart`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/keycloak_client.dart test/keycloak_client_test.dart
git commit -m "feat: inject the login strategy and credentials store publicly"
```

---

### Task 3: `MobileLoginStrategy` on `flutter_web_auth_2`

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/src/models/platform_config.dart` (`MobileConfig`)
- Rewrite: `lib/src/strategies/mobile_login_strategy.dart`
- Test: `test/src/strategies/mobile_login_strategy_test.dart` (create)

- [ ] **Step 1: Dependencies**

In `pubspec.yaml`:
- under `environment:`, change `flutter: ">=1.17.0"` to `flutter: ">=3.24.0"`;
- under `dependencies:`, delete `  app_links: ^7.0.0` and add `  flutter_web_auth_2: ^5.1.0`.

Run: `flutter pub get`
Expected: `Got dependencies!`

- [ ] **Step 2: Write the failing tests**

Create `test/src/strategies/mobile_login_strategy_test.dart`:

```dart
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:keycloak_client/keycloak_client.dart';
import 'package:keycloak_client/src/strategies/mobile_login_strategy.dart';

const _config = ClientConfig(baseUrl: 'http://localhost', realm: 'test', clientId: 'app');

/// Stands in for FlutterWebAuth2.authenticate: records the call and answers
/// with [respond], which receives the `state` the strategy sent.
final class FakeAuthSession {
  final String Function(String state) respond;
  final Object? throws;

  String? url;
  String? callbackUrlScheme;
  FlutterWebAuth2Options? options;

  FakeAuthSession(this.respond, {this.throws});

  Future<String> authenticate({
    required String url,
    required String callbackUrlScheme,
    FlutterWebAuth2Options options = const FlutterWebAuth2Options(),
  }) async {
    this.url = url;
    this.callbackUrlScheme = callbackUrlScheme;
    this.options = options;
    if (throws != null) throw throws!;
    return respond(Uri.parse(url).queryParameters['state']!);
  }
}

void main() {
  late List<http.Request> tokenRequests;
  late http.Client tokenEndpoint;

  setUp(() {
    tokenRequests = [];
    tokenEndpoint = MockClient((request) async {
      tokenRequests.add(request);
      return http.Response(
        jsonEncode({'access_token': 'at', 'token_type': 'Bearer', 'expires_in': 300, 'refresh_token': 'rt'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  });

  Future<dynamic> login(FakeAuthSession session, [MobileConfig config = const MobileConfig()]) =>
      MobileLoginStrategy.withAuthenticator(session.authenticate, httpClient: tokenEndpoint)
          .login(platformConfig: config, clientConfig: _config);

  test('exchanges the returned code with the PKCE verifier', () async {
    final session = FakeAuthSession((state) => 'myapp://auth?code=abc&state=$state');

    final client = await login(session);

    expect(client.credentials.accessToken, 'at');
    expect(Uri.parse(session.url!).queryParameters['code_challenge'], isNotEmpty);
    final exchange = tokenRequests.single.bodyFields;
    expect(exchange['grant_type'], 'authorization_code');
    expect(exchange['code'], 'abc');
    expect(exchange['code_verifier'], hasLength(64));
  });

  test('runs a private session for the redirect scheme by default', () async {
    final session = FakeAuthSession((state) => 'myapp://auth?code=abc&state=$state');

    await login(session);

    expect(session.callbackUrlScheme, 'myapp');
    expect(session.options!.preferEphemeral, isTrue);
    expect(session.options!.httpsHost, isNull);
  });

  test('preferEphemeral false is passed through', () async {
    final session = FakeAuthSession((state) => 'myapp://auth?code=abc&state=$state');

    await login(session, const MobileConfig(preferEphemeral: false));

    expect(session.options!.preferEphemeral, isFalse);
  });

  test('an https redirect passes its host and path', () async {
    final session = FakeAuthSession((state) => 'https://app.example.com/auth/callback?code=abc&state=$state');

    await login(session, const MobileConfig(redirectUri: 'https://app.example.com/auth/callback'));

    expect(session.callbackUrlScheme, 'https');
    expect(session.options!.httpsHost, 'app.example.com');
    expect(session.options!.httpsPath, '/auth/callback');
  });

  test('a dismissed session is a cancellation', () async {
    final session = FakeAuthSession((_) => '', throws: PlatformException(code: 'CANCELED'));

    expect(await login(session), isNull);
    expect(tokenRequests, isEmpty);
  });

  test('access_denied is a cancellation', () async {
    final session = FakeAuthSession((state) => 'myapp://auth?error=access_denied&state=$state');

    expect(await login(session), isNull);
  });

  test('any other IdP error is a server error', () async {
    final session = FakeAuthSession((state) => 'myapp://auth?error=server_error&state=$state');

    await expectLater(login(session), throwsA(isA<KeycloakServerException>()));
  });

  test('a callback with a foreign state is rejected', () async {
    final session = FakeAuthSession((_) => 'myapp://auth?code=abc&state=forged');

    await expectLater(login(session), throwsA(isA<KeycloakServerException>()));
    expect(tokenRequests, isEmpty, reason: 'a forged code was exchanged');
  });

  test('a session that cannot start is a network error', () async {
    final session = FakeAuthSession((_) => '', throws: PlatformException(code: 'EXTRA_PARAMETERS_ERROR'));

    await expectLater(login(session), throwsA(isA<KeycloakNetworkException>()));
  });
}
```

- [ ] **Step 3: Run the tests and confirm they fail**

Run: `flutter test test/src/strategies/mobile_login_strategy_test.dart`
Expected: compile errors: `withAuthenticator` isn't defined, and there's no named parameter `preferEphemeral`.

- [ ] **Step 4: Implement `MobileConfig`**

In `lib/src/models/platform_config.dart`, replace the whole `MobileConfig` class with:

```dart
/// Mobile-specific configuration options.
final class MobileConfig extends PlatformConfig {
  /// Whether the login runs in a private browser session. Defaults to `true`.
  ///
  /// A private session shares no cookies with the system browser: iOS shows no
  /// "wants to use … to Sign In" prompt, and every login asks for credentials
  /// (refresh tokens keep users signed in between logins). Set `false` to
  /// share the browser's Keycloak session for single sign-on, at the cost of
  /// that prompt on iOS.
  final bool preferEphemeral;

  const MobileConfig({
    super.redirectUri = 'myapp://auth',
    this.preferEphemeral = true,
  });
}
```

- [ ] **Step 5: Implement the strategy**

Replace the whole of `lib/src/strategies/mobile_login_strategy.dart` with:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:oauth2/oauth2.dart';

import '../models/client_config.dart';
import '../models/keycloak_exception.dart';
import '../models/platform_config.dart';
import '../interfaces/login_strategy.dart';
import '../utilities/pkce.dart';

/// The signature of [FlutterWebAuth2.authenticate], injectable for tests.
typedef WebAuthenticate = Future<String> Function({
  required String url,
  required String callbackUrlScheme,
  FlutterWebAuth2Options options,
});

/// Mobile login in an in-app auth session: `ASWebAuthenticationSession` on
/// iOS, Auth Tab / Custom Tabs on Android.
///
/// The session is shown over the app and hands the callback URL straight back,
/// so there is no deep-link listener, no "Open in app?" prompt and no browser
/// left behind. On Android the consumer registers `flutter_web_auth_2`'s
/// `CallbackActivity` for the redirect scheme; a custom scheme needs no iOS
/// setup.
final class MobileLoginStrategy implements IMobileLoginStrategy {
  final WebAuthenticate _authenticate;
  final http.Client? _httpClient;

  const MobileLoginStrategy() : this.withAuthenticator(FlutterWebAuth2.authenticate);

  /// [httpClient] carries the code exchange, so tests can fake the token
  /// endpoint.
  @visibleForTesting
  const MobileLoginStrategy.withAuthenticator(WebAuthenticate authenticate, {http.Client? httpClient})
    : _authenticate = authenticate,
      _httpClient = httpClient;

  @override
  Future<Client?> login({
    required MobileConfig platformConfig,
    required ClientConfig clientConfig,
  }) async {
    final grant = AuthorizationCodeGrant(
      clientConfig.clientId,
      clientConfig.authorizationEndpoint,
      clientConfig.tokenEndpoint,
      secret: clientConfig.clientSecret,
      codeVerifier: generateCodeVerifier(),
      httpClient: _httpClient,
    );

    final redirect = Uri.parse(platformConfig.redirectUri);
    final authUrl = grant.getAuthorizationUrl(
      redirect,
      scopes: clientConfig.scopes,
      state: generateState(),
    );
    final isHttps = redirect.scheme == 'https';

    final String result;
    try {
      result = await _authenticate(
        url: authUrl.toString(),
        callbackUrlScheme: redirect.scheme,
        options: FlutterWebAuth2Options(
          preferEphemeral: platformConfig.preferEphemeral,
          // flutter_web_auth_2 needs these to match an https (app / universal
          // link) redirect.
          httpsHost: isHttps ? redirect.host : null,
          httpsPath: isHttps ? redirect.path : null,
        ),
      );
    } on PlatformException catch (e) {
      // The sheet was dismissed on iOS, or on Android the user came back to
      // the app without finishing.
      if (e.code == 'CANCELED') return null;
      throw KeycloakNetworkException(e);
    }

    final params = Uri.parse(result).queryParameters;
    final error = params['error'];
    if (error != null) {
      if (error == 'access_denied') return null; // user cancelled
      throw KeycloakServerException(400, error);
    }

    try {
      return await grant.handleAuthorizationResponse(params);
    } on AuthorizationException catch (e) {
      throw KeycloakServerException(400, e.error);
    } on FormatException catch (e) {
      // Raised by oauth2 when the callback's `state` does not match the one
      // sent — a code delivered by someone other than the IdP we redirected to.
      throw KeycloakServerException(400, e.message);
    }
  }
}
```

- [ ] **Step 6: Run the tests and confirm they pass**

Run: `flutter test test/src/strategies/mobile_login_strategy_test.dart`
Expected: 9 tests pass.

If the foreign-state test fails because oauth2 throws something other than `AuthorizationException` or `FormatException` for a state mismatch, map that exception type to `KeycloakServerException` as well. Report it as a deviation.

- [ ] **Step 7: Run everything**

Run: `flutter test test/keycloak_client_test.dart test/src test/public_api_test.dart` and `flutter analyze`
Expected: everything passes, with no new analyzer issues. Confirm with `git grep -n "app_links\|deepLinkTimeout" -- lib test example/lib` that neither name is still referenced.

- [ ] **Step 8: Build check**

Run in `example/`: `flutter build apk --debug`
Expected: a successful build, which validates the merged manifest and compileSdk. If no Android SDK is available, report the build as skipped; don't claim it passed. Task 4 changes the example manifest, so run this build again there.

- [ ] **Step 9: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/src/models/platform_config.dart lib/src/strategies/mobile_login_strategy.dart test/src/strategies/mobile_login_strategy_test.dart
git commit -m "feat: mobile login in an in-app auth session (flutter_web_auth_2)"
```

`pubspec.lock` is gitignored, so `git add` skips it, which is fine. If the example's lock file changed because of the new dependency, it may be committed with this task.

---

### Task 4: Example app, README, CHANGELOG

**Files:**
- Modify: `example/android/app/src/main/AndroidManifest.xml`
- Modify: `example/ios/Runner/Info.plist`
- Modify: `README.md` (Configuration, `## Android`, `## iOS`, a new section, Main API, Notes)
- Modify: `CHANGELOG.md` (the existing 4.0.0 entry)

- [ ] **Step 1: Example Android manifest**

In `example/android/app/src/main/AndroidManifest.xml`:
- delete the second `<intent-filter>` of `MainActivity`, the one with `VIEW` and `<data android:scheme="myapp" android:host="auth"/>`;
- add `android:taskAffinity=""` to the `MainActivity` `<activity>` tag;
- add this activity inside `<application>`, after `MainActivity`:

```xml
        <!-- Receives the login redirect for flutter_web_auth_2's auth session. -->
        <activity
            android:name="com.linusu.flutter_web_auth_2.CallbackActivity"
            android:exported="true"
            android:taskAffinity="">
            <intent-filter android:label="flutter_web_auth_2">
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="myapp"/>
            </intent-filter>
        </activity>
```

- [ ] **Step 2: Example iOS `Info.plist`**

In `example/ios/Runner/Info.plist`, delete the `CFBundleURLTypes` key and the whole `<array>` that follows it. `ASWebAuthenticationSession` matches the scheme itself.

- [ ] **Step 3: README**

- **`## Configuration`, "Platform config defaults":** replace the `MobileConfig.redirectUri` bullet with:
  ```markdown
  - `MobileConfig.redirectUri`: `myapp://auth`
  - `MobileConfig.preferEphemeral`: `true` — a private auth session: no iOS "wants to use … to Sign In" prompt and no cookies shared with the browser. Set `false` for single sign-on with the browser's Keycloak session
  ```
- **Replace the whole `## Android` section,** up to `## iOS`, with:
  ````markdown
  ## Android

  Mobile login runs in an Auth Tab / Custom Tab via
  [`flutter_web_auth_2`](https://pub.dev/packages/flutter_web_auth_2). Register
  its callback activity for your redirect scheme in
  `android/app/src/main/AndroidManifest.xml`, inside `<application>`:

  ```xml
  <activity
      android:name="com.linusu.flutter_web_auth_2.CallbackActivity"
      android:exported="true"
      android:taskAffinity="">
      <intent-filter android:label="flutter_web_auth_2">
          <action android:name="android.intent.action.VIEW"/>
          <category android:name="android.intent.category.DEFAULT"/>
          <category android:name="android.intent.category.BROWSABLE"/>
          <data android:scheme="myapp"/>
      </intent-filter>
  </activity>
  ```

  Remove any `VIEW` intent filter for this scheme from `MainActivity`; two
  activities claiming it makes Android ask the user which one to open. Also set
  `android:taskAffinity=""` on `MainActivity`, as `flutter_web_auth_2`
  recommends. `flutter_web_auth_2` compiles against Android SDK 36, so your app
  may need `compileSdk = 36`.

  Also ensure internet permission exists:

  ```xml
  <uses-permission android:name="android.permission.INTERNET"/>
  ```

  For an `https` redirect (App Links), use `https` as the scheme in the intent
  filter with your host, and set `MobileConfig.redirectUri` to the full URL.
  ````
- **Replace the whole `## iOS` section,** up to `## macOS / Windows / Linux`, with:
  ```markdown
  ## iOS

  Mobile login runs in an `ASWebAuthenticationSession` sheet over your app, and
  it matches the redirect scheme itself. A custom scheme such as
  `myapp://auth` needs no `Info.plist` entry. An `https` redirect (universal
  link) requires iOS 17.4 or later and an associated domain.
  ```
- **Add a section before `## Dev Redirect Helper`:**
  ````markdown
  ## Custom Login and Storage

  Every dependency can be replaced through the public constructor:

  ```dart
  final client = KeycloakClient(
    clientConfig: config,
    credentialsStorage: MyStore(),            // default: SecureStorageAuthCredentialsStore
    mobileLoginStrategy: MyMobileStrategy(),  // implements IMobileLoginStrategy
  );
  ```

  Only the strategy for the platform the app runs on is used. A custom strategy
  can reuse `generateCodeVerifier()` and `generateState()` for PKCE, and
  `SecureStorageAuthCredentialsStore` is exported so it can be wrapped or
  reused.
  ````
- **`## Notes`:** change the `flutter_secure_storage` bullet to:
  ```markdown
  - Credentials are stored with `flutter_secure_storage` by default (`SecureStorageAuthCredentialsStore`); pass `credentialsStorage` to change it
  ```

- [ ] **Step 4: CHANGELOG**

In the existing `## 4.0.0` entry, don't add a new heading. Append these to the end of `### Breaking`:

```markdown
- Mobile login now runs in an in-app auth session (`ASWebAuthenticationSession`
  on iOS, Auth Tab / Custom Tabs on Android) via `flutter_web_auth_2`, instead
  of opening the system browser and waiting for a deep link. On iOS this
  removes the "Open in app?" prompt and the Safari window left behind.
  - Android: move the `VIEW` intent filter from `MainActivity` to
    `com.linusu.flutter_web_auth_2.CallbackActivity` (see README). Apps may
    need `compileSdk = 36`.
  - iOS: the `CFBundleURLTypes` entry for the redirect scheme is no longer
    needed.
- `MobileConfig.deepLinkTimeout` is removed: the auth session has no timeout,
  and on Android an abandoned login is cancelled when the user returns to the
  app. `login()` returns `null` on cancellation, as before.
- Requires Flutter 3.24 or later. `app_links` is no longer a dependency.
```

Append these to the end of `### New`:

```markdown
- `MobileConfig.preferEphemeral` (default `true`): a private auth session with
  no iOS sign-in prompt; `false` shares the browser's Keycloak session.
- `KeycloakClient(...)` accepts `credentialsStorage`, `mobileLoginStrategy`,
  `desktopLoginStrategy` and `webLoginStrategy`, so a custom strategy or store
  no longer needs the `@visibleForTesting` `withDependencies` constructor.
- `SecureStorageAuthCredentialsStore`, `generateCodeVerifier()` and
  `generateState()` are exported.
```

- [ ] **Step 5: Verify**

Run: `flutter analyze`, then `flutter test test/keycloak_client_test.dart test/src test/public_api_test.dart`, then in `example/` `flutter build apk --debug` (or report it as skipped).
Expected: no new analyzer issues, all tests pass, and the build succeeds.

- [ ] **Step 6: Commit**

```bash
git add example/android/app/src/main/AndroidManifest.xml example/ios/Runner/Info.plist README.md CHANGELOG.md
git commit -m "docs: auth-session setup and public injection (4.0.0)"
```
