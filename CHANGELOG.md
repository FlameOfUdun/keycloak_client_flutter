# CHANGELOG

## 2.1.0

### New

- `getAccountCredentials()` — queries Keycloak's account REST API
  (`/realms/{realm}/account/credentials`) and returns the list of credential
  types configured for the current user as a sealed `AccountCredential`
  family. Subtypes (`PasswordCredential`, `OtpCredential`,
  `WebAuthnCredential`) expose per-type fields parsed from the response,
  including OTP `subType`/`digits`/`period`/`algorithm` and WebAuthn
  `aaguid`. Unknown credential types fall back to `UnknownCredential` so
  realm-specific or future credential providers don't break the client.
- `ClientConfig.accountCredentialsEndpoint` — exposed for completeness.

## 2.0.0

### Breaking Changes

- `getAuthToken()` now throws `KeycloakNetworkException` when the session is valid
  but a network error prevents token refresh. Previously it returned `null`, making
  "device is offline" indistinguishable from "no session". Update call sites:

  ```dart
  // Before
  final token = await client.getAuthToken();
  if (token == null) showLoginScreen();

  // After
  try {
    final token = await client.getAuthToken();
    if (token == null) showLoginScreen(); // genuinely no session
  } on KeycloakNetworkException {
    showOfflineBanner(); // transient — user is still signed in
  }
  ```

- `KeycloakClient` constructor now accepts optional `webConfig`, `mobileConfig`, and
  `desktopConfig` named parameters directly instead of embedding them inside
  `ClientConfig`. Pass platform-specific configuration at the client level:

  ```dart
  KeycloakClient(
    clientConfig: ClientConfig(...),
    mobileConfig: MobileConfig(redirectUri: 'myapp://auth'),
    desktopConfig: DesktopConfig(loopbackUri: Uri.parse('http://localhost:9000/cb')),
  )
  ```

### Bug Fixes

- Token refresh no longer hangs indefinitely on unresponsive networks. A configurable
  `refreshTimeout` (default 15 s) is applied to every refresh HTTP request; a timeout
  is treated as a transient failure and retried automatically.
- `initialize()` no longer triggers a second token refresh when the access token is
  expired and the server is unreachable. Previously the offline startup time was up to
  30 s (two sequential timeouts); it is now at most `refreshTimeout` (15 s by default).
- The refresh retry loop no longer runs indefinitely past the local refresh token
  expiry. Both `SocketException` and non-`invalid_grant` authorization error retry
  paths now check `isRefreshExpired` before scheduling a retry; if expired, the
  session ends immediately with `AuthState.sessionExpired`.

### New

- `ClientConfig.refreshTimeout` — controls the per-request HTTP timeout for token
  refresh. Defaults to `Duration(seconds: 15)`. Lower it for faster offline detection;
  raise it for slow or high-latency Keycloak deployments.
- `refreshToken()` — forces an immediate token refresh regardless of access token
  expiry, then reloads the user profile. Throws `KeycloakNetworkException` if the
  server is unreachable. Useful after returning from account management or when an
  admin has changed the user's roles and updated claims are needed immediately.

### Improvements

- User profile is automatically re-fetched when the device recovers from a network
  outage (refresh transitions from failing to succeeding), preventing a stale
  `currentUser` after the app comes back online.
- Internal architecture: `SessionManager` (identity) and `TokenService` (transport)
  are now separate classes, matching Firebase Auth's separation of concerns.
  `AuthState` and `currentUser` are never affected by transient network events.

---

## 1.1.1

- Fix for stale user info when refresh is unsuccessful

## 1.0.1

- Tiny tweaks

## 1.0.0

### **Breaking changes**

- `KeycloakClient` constructor now takes a single `ClientConfig` object instead of individual parameters
- `idToken` on `UserCredentials` is now nullable (`String?`) — non-OIDC flows may not return an ID token

### **New features**

- **Platform-specific login strategies*- — the library automatically selects the right strategy at runtime:
  - `DesktopLoginStrategy` — localhost `HttpServer` loopback + system browser (Windows, macOS, Linux)
  - `MobileLoginStrategy` — system browser + deep-link callback via `app_links`
  - `WebLoginStrategy` — same-tab redirect flow; persists a pending grant in `sessionStorage` across the redirect
- `ClientConfig` — single configuration object replacing individual constructor parameters; exposes computed endpoint URIs (`authorizationEndpoint`, `tokenEndpoint`, `userInfoEndpoint`, `logoutEndpoint`)
- `PlatformConfig` sealed hierarchy — `DesktopConfig`, `MobileConfig`, `WebConfig` with platform-specific knobs (loopback URI, timeout, success page HTML, pending-grant TTL, custom launch callback)
- `handleWebCallback(Uri)` — call once on app startup to complete in-progress web redirect flows
- `KeycloakTimeoutException` — new typed exception thrown when the browser does not redirect back within the configured timeout
- PKCE (`code_verifier` / `code_challenge`) enabled on all platforms
- `UserCredentials.fromOAuth2` and `UserCredentials.toOAuth2Credentials` — interop with the `oauth2` package
- `DesktopConfig.clientSecret` support for confidential clients

### **Improvements**

- Replaced `dio` + `flutter_web_auth_2` with the `oauth2` package — one transport, one token-exchange path
- `onAuthChange` and `onUserChange` streams share a single `_bufferedStream` helper — no more duplicated stream controller code
- Log messages trimmed and made consistent

### **Dependency updates**

- Added `oauth2: ^2.0.5`, `url_launcher: ^6.3.2`, `web: ^1.1.1`, `app_links: ^7.0.0`
- Updated `flutter_secure_storage`: `^9.2.4` → `^10.0.0`, `dio`: `^5.8.0+1` → `^5.9.2`
- Removed `flutter_web_auth_2`

### **Example app**

- Added web and Windows platform targets
- Updated example to demonstrate `ClientConfig` and `handleWebCallback`

## 0.0.1

- Authorization Code flow login via system browser (`login()`)

- Persistent session storage via `flutter_secure_storage`
- Reactive authentication state stream (`onAuthChange`)
- Reactive user profile stream (`onUserChange`)
- On-demand access token retrieval with automatic refresh (`getAuthToken()`)
- User profile reload from Keycloak userinfo endpoint (`reloadUser()`)
- Typed exceptions: `KeycloakNetworkException`, `KeycloakServerException`, `KeycloakSessionExpiredException`
- Configurable OAuth scopes
- Configurable log verbosity via `LogLevel`
