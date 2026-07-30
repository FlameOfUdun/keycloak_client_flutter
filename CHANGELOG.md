# CHANGELOG

## 3.0.0

### New

- `onTokenRefreshed` — emits after every successful token refresh while a
  session is active, on both refresh paths (the scheduled timer and the inline
  refresh inside `getAuthToken()`). Refreshes were previously invisible from
  outside the client, which is fine for code that calls `getAuthToken()` per
  request but not for a connection authenticated once at dial time: a WebSocket
  or gRPC channel would hold a token that expired underneath it.

  The stream carries no value — call `getAuthToken()` for the new token. Unlike
  `onAuthChange` and `onUserChange` it does not replay on listen, and it stays
  silent while signed out, including for the refresh `initialize()` performs on
  a cold start with an expired access token.

- `ClientConfig.refreshTokenLifetime` — how long a refresh token is assumed to
  stay valid, defaulting to 30 days. `package:oauth2` discards the token
  response's `refresh_expires_in`, so this cannot be read from the server; set
  it to match the realm's **SSO Session Max**.
- `ClientConfig.isOfflineSession` — true when `offline_access` is among
  `scopes`. The only offline signal available on the client, for the same
  reason.
- `PendingGrant` is now exported. It appears in `IPendingGrantStore`'s
  signature, so implementing that interface required a type you could not name.

### Bug Fixes

- **Offline tokens no longer degrade into 30-day ones.** `isOfflineToken` was
  never set anywhere: both credential-writing paths called
  `UserCredentials.fromOAuth2` without it, so a session opened with
  `offline_access` was stored as an ordinary one with an invented 30-day
  refresh expiry. On day 31 `initialize()` ended a session Keycloak would still
  have honoured. Offline-ness and the assumed lifetime are now supplied on
  every write, taken from `ClientConfig`.

- **Desktop and mobile logins now send an OAuth `state` parameter.** Only the
  web strategy did. `package:oauth2` does not generate one for you, and it
  validates the callback's `state` only when one was supplied — so both flows
  accepted any callback carrying a `code`. PKCE kept this from being directly
  exploitable, but the desktop loopback listener would accept a code from any
  local origin. RFC 6749 §10.12.

- **`WebLoginStrategy.withDependencies` now honours its `redirect` argument.**
  It was `required`, documented as recording the URL instead of navigating, and
  silently discarded — so a test written against its own documentation
  navigated the real browser tab.

- **`WebConfig.pendingGrantTTL` now has an effect.** The strategy built its
  store with a hardcoded default and never read the configured value, so the
  documented setting did nothing and the two defaults disagreed (15 minutes
  documented, 10 applied). The TTL now rides on the persisted `PendingGrant`,
  which is also what lets `handleCallback` judge expiry after the page reload
  that ends the redirect.

- **Mobile login no longer races the deep link.** `AppLinks` was subscribed
  *after* the browser launched, so a user already signed in at Keycloak could
  be bounced back before anything was listening — hanging the login for the
  full `deepLinkTimeout`. The listener is now attached first, as the desktop
  strategy has always done with its loopback server.

- A login-listener port already in use now throws `KeycloakNetworkException`
  instead of a raw `SocketException`, so callers catching `KeycloakException`
  see it.

- `MobileLoginStrategy` had a `try { … } on KeycloakTimeoutException
  { rethrow; }` with no other catch and no finally. Removed.

### Breaking

- Logging now goes through `package:logging` instead of `package:logger`, and
  `ClientConfig.logLevel` and the `LogLevel` enum are gone with it. The client
  logs under the logger name `KeycloakClient` and prints nothing on its own —
  the app installs a listener and picks the level. See the Logging section of
  the README.

  To migrate, drop `logLevel` from your `ClientConfig` and configure
  `package:logging` at startup:

  ```dart
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) => debugPrint('${r.level.name}: ${r.message}'));
  ```

- `refreshToken()` now throws `KeycloakSessionExpiredException` when the
  refresh turned out to be permanently dead. It previously returned normally,
  so an awaiting caller could not tell "refreshed" from "your session just
  ended" without separately watching `onAuthChange`. This also makes
  `KeycloakSessionExpiredException` reachable — it was exported and documented
  but never thrown by anything.

- A login strategy now throws `KeycloakServerException` when the IdP returns an
  `error` other than `access_denied`. Every error code was previously reported
  as `null`, i.e. "the user cancelled", so a misconfigured client or an invalid
  scope was indistinguishable from someone changing their mind. `access_denied`
  still returns `null`, because that genuinely is a cancellation.

- `IWebLoginStrategy.handleCallback` takes a `clientSecret` named argument, and
  `PendingGrant` no longer carries one. The grant is persisted to
  `sessionStorage`, readable by any script on the origin; the secret now comes
  from the live `ClientConfig` at callback time. A browser client should be a
  public one with no secret at all, but the record no longer publishes it if
  there is.

- `PendingGrant.isExpired(Duration)` is now the getter `isExpired`, reading the
  `ttlMs` the record carries, and `SessionStoragePendingGrantStore` no longer
  takes a `ttl`.

- `UserCredentials.fromApi` removed. It parsed a raw Keycloak token response —
  a shape this package never receives, since `package:oauth2` performs the
  exchange — so nothing called it and nothing tested it.

- `DesktopLoginStrategy.generateCodeVerifier` removed. It was the only public
  one of three identical copies; all three now share
  `generateCodeVerifier()`/`generateState()` internally.

### Bug Fixes

- Logout again revokes the session at Keycloak when the user has no ID token.
  The `id_token_hint` field was being sent as a literal null instead of being
  omitted, which made the request body a `Map<String, String?>`; `http` throws
  when it casts that to form fields, and `revokeSession` swallows the throw. The
  local session still cleared, so a logout looked successful while the refresh
  token stayed valid server-side.

## 2.1.1

### Bug Fixes

- `AccountCredential.fromJson` now reads instances from the correct field on
  the Keycloak response. Keycloak's account REST API returns configured
  instances under `userCredentialMetadatas` (each wrapped in a metadata
  envelope with the actual credential under `.credential`), not
  `userCredentials`. The previous lookup missed every entry and reported
  `instanceCount: 0` / `isConfigured: false` for credentials the user had
  actually configured. The parser now reads `userCredentialMetadatas` first
  and unwraps each envelope, falling back to the flat `userCredentials`
  shape for compatibility with older or alternative response paths.

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
