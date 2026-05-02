# CHANGELOG

## 1.0.0

### **Breaking changes**

* `KeycloakClient` constructor now takes a single `ClientConfig` object instead of individual parameters
* `idToken` on `UserCredentials` is now nullable (`String?`) — non-OIDC flows may not return an ID token

### **New features**

* **Platform-specific login strategies** — the library automatically selects the right strategy at runtime:
  * `DesktopLoginStrategy` — localhost `HttpServer` loopback + system browser (Windows, macOS, Linux)
  * `MobileLoginStrategy` — system browser + deep-link callback via `app_links`
  * `WebLoginStrategy` — same-tab redirect flow; persists a pending grant in `sessionStorage` across the redirect
* `ClientConfig` — single configuration object replacing individual constructor parameters; exposes computed endpoint URIs (`authorizationEndpoint`, `tokenEndpoint`, `userInfoEndpoint`, `logoutEndpoint`)
* `PlatformConfig` sealed hierarchy — `DesktopConfig`, `MobileConfig`, `WebConfig` with platform-specific knobs (loopback URI, timeout, success page HTML, pending-grant TTL, custom launch callback)
* `handleWebCallback(Uri)` — call once on app startup to complete in-progress web redirect flows
* `KeycloakTimeoutException` — new typed exception thrown when the browser does not redirect back within the configured timeout
* PKCE (`code_verifier` / `code_challenge`) enabled on all platforms
* `UserCredentials.fromOAuth2` and `UserCredentials.toOAuth2Credentials` — interop with the `oauth2` package
* `DesktopConfig.clientSecret` support for confidential clients

### **Improvements**

* Replaced `dio` + `flutter_web_auth_2` with the `oauth2` package — one transport, one token-exchange path
* `onAuthChange` and `onUserChange` streams share a single `_bufferedStream` helper — no more duplicated stream controller code
* Log messages trimmed and made consistent

### **Dependency updates**

* Added `oauth2: ^2.0.5`, `url_launcher: ^6.3.2`, `web: ^1.1.1`, `app_links: ^7.0.0`
* Updated `flutter_secure_storage`: `^9.2.4` → `^10.0.0`, `dio`: `^5.8.0+1` → `^5.9.2`
* Removed `flutter_web_auth_2`

### **Example app**

* Added web and Windows platform targets
* Updated example to demonstrate `ClientConfig` and `handleWebCallback`

## 0.0.1

* Authorization Code flow login via system browser (`login()`)

* Persistent session storage via `flutter_secure_storage`
* Reactive authentication state stream (`onAuthChange`)
* Reactive user profile stream (`onUserChange`)
* On-demand access token retrieval with automatic refresh (`getAuthToken()`)
* User profile reload from Keycloak userinfo endpoint (`reloadUser()`)
* Typed exceptions: `KeycloakNetworkException`, `KeycloakServerException`, `KeycloakSessionExpiredException`
* Configurable OAuth scopes
* Configurable log verbosity via `LogLevel`
