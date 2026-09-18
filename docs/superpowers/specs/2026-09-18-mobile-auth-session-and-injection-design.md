# Mobile auth session and public injection — design

**Date:** 2026-09-18
**Status:** Approved in conversation
**Source:** GitHub issue FlameOfUdun/keycloak_client_flutter#2
**Release:** 4.0.0, shipped together with service-account mode and required roles

## Problem

1. `MobileLoginStrategy` runs `launchUrl(authUrl, mode: LaunchMode.externalApplication)`
   and waits for an `app_links` deep link.
   - **iOS:** the Safari app takes over the screen. iOS then asks "Open in
     \<App\>?" before handing the callback over, and Safari stays open behind
     the app afterwards.
   - **Android:** a Chrome tab is left behind.
2. There's no public way to install a different strategy:
   - The public `KeycloakClient(...)` constructor hard-codes the strategy.
   - `withDependencies` is `@visibleForTesting`, and its `credentialsStorage`
     is required.
   - The default `SecureStorageAuthCredentialsStore` isn't exported.
   - The PKCE helpers aren't exported either.

## Decisions

1. **The mobile strategy uses `flutter_web_auth_2` ^5.1.0.** That means
   `ASWebAuthenticationSession` on iOS and Auth Tab / Custom Tabs on Android. The
   sheet appears over the app and the callback URL comes back straight to the
   caller.
2. **`MobileConfig.preferEphemeral`**, default **`true`**, gives a private
   session:
   - iOS shows no "wants to use … to Sign In" prompt.
   - No cookies are shared with the system browser, so every login asks for
     credentials. Refresh tokens keep users signed in between logins anyway.
   - The flag is passed straight through, and it also applies on Android.
3. **`MobileConfig.deepLinkTimeout` is removed.** `flutter_web_auth_2` has no
   timeout on iOS or Android, and nothing can close the sheet from outside.
   Android cancels a pending call by itself when the user returns to the app
   without finishing.
4. **Cancellation:** `PlatformException(code: 'CANCELED')` → `login()` returns
   `null`, the same as `error=access_denied`. Any other `PlatformException` →
   `KeycloakNetworkException(e)`.
5. **HTTPS redirects:** when `MobileConfig.redirectUri` uses `https`, the
   strategy passes `callbackUrlScheme: 'https'`, `httpsHost` and `httpsPath`.
   `flutter_web_auth_2` requires both on Android. On iOS this path needs iOS
   17.4 or later.
6. **Dependencies:**
   - `app_links` is removed. Nothing else uses it.
   - `url_launcher` stays, for desktop login and `manageAccount()`.
   - The package's Flutter constraint becomes `>=3.24.0`, which
     `flutter_web_auth_2` requires.
7. **Public injection:** `KeycloakClient(...)` gains optional parameters:
   `credentialsStorage`, `mobileLoginStrategy`, `desktopLoginStrategy` and
   `webLoginStrategy`. The strategy for the current platform is chosen with the
   existing `_selectLoginStrategy`. In `withDependencies`, `credentialsStorage`
   becomes optional; that constructor stays `@visibleForTesting` for its test
   seams (`tokenRefreshOperation`, `httpClient`).
8. **Exports:**
   - `SecureStorageAuthCredentialsStore`, which is also the default everywhere
     a store is optional. Its storage keys don't change, so upgrading doesn't
     sign anyone out.
   - `generateCodeVerifier()` and `generateState()`.

## Strategy shape

```dart
typedef WebAuthenticate = Future<String> Function({
  required String url,
  required String callbackUrlScheme,
  FlutterWebAuth2Options options,
});

final class MobileLoginStrategy implements IMobileLoginStrategy {
  const MobileLoginStrategy() : this.withAuthenticator(FlutterWebAuth2.authenticate);

  @visibleForTesting
  const MobileLoginStrategy.withAuthenticator(this._authenticate, {http.Client? httpClient});
}
```

PKCE, `state`, `handleAuthorizationResponse` and the mapping of other errors
stay the same. `httpClient` lets tests fake the token endpoint used in the code
exchange.

## Consumer setup changes (breaking, documented in the README and CHANGELOG)

- **Android:** the `VIEW` intent filter moves from `MainActivity` to
  `com.linusu.flutter_web_auth_2.CallbackActivity`, with `exported="true"` and
  `taskAffinity=""`. `flutter_web_auth_2` compiles against SDK 36, so apps may
  need `compileSdk` 36.
- **iOS:** the `CFBundleURLTypes` entry for the scheme is no longer needed.
- **Code:** remove `MobileConfig.deepLinkTimeout`, and upgrade to Flutter 3.24
  or later.

The example app's `AndroidManifest.xml` and `Info.plist` are updated to match.

## Testing

Strategy tests go through `withAuthenticator` and a mock token endpoint:
- a successful exchange sends `code` and `code_verifier`;
- the callback scheme and options are passed, with `preferEphemeral` true by
  default;
- an `https` redirect passes the scheme, host and path;
- `CANCELED` → `null`;
- `access_denied` → `null`;
- another `error` → `KeycloakServerException`;
- a `state` mismatch → `KeycloakServerException`;
- another `PlatformException` → `KeycloakNetworkException`.

`KeycloakClient` tests check that the public constructor uses an injected
strategy and store. A public-API test checks the exports compile and behave.
