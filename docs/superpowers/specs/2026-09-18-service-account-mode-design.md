# Service-account mode — design

**Date:** 2026-09-18
**Status:** Draft, awaiting review

## Goal

Let `KeycloakClient` authenticate as a Keycloak **service account**, meaning the
OAuth2 client-credentials grant (`client_id` + `client_secret`, no user or
browser), through the public API it already has.

## Non-goals

- A separate class or package. The mode lives inside `KeycloakClient`.
- Pure-Dart (non-Flutter) support. The package still depends on Flutter.
- Client authentication other than a secret (signed JWT, mTLS).
- New HTTP helpers such as an authenticated `http.Client` or a Dio interceptor.

## Public API change

Exactly one addition: an optional field on `ClientConfig`.

```dart
enum GrantType { authorizationCode, clientCredentials }

const ClientConfig({
  ...,
  this.clientSecret,                            // unchanged, still optional
  this.grantType = GrantType.authorizationCode, // new
});
```

`GrantType` lives in `lib/src/enums/grant_type.dart` and is exported from
`keycloak_client.dart`. Existing code compiles and behaves as before.

The presence of `clientSecret` is **not** the switch. Confidential clients
already pass a secret for browser login and must keep getting a browser.

## Usage

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

await client.login();                 // no browser; fetches a token
final token = await client.getAuthToken();
```

## Behaviour of the existing API in service-account mode

| API | Behaviour |
|---|---|
| constructor | Throws `ArgumentError` if `clientSecret` is null or empty. |
| `login()` | Runs `oauth2.clientCredentialsGrant(tokenEndpoint, clientId, clientSecret, scopes: scopes)`, then the existing `_finalizeLogin`. The platform login strategy is never used. The existing in-flight join still applies. |
| `initialize()` | Unchanged. It restores the stored token, and an expired one is renewed through the refresh path below. |
| `getAuthToken()` / `refreshToken()` / scheduled refresh | Unchanged `TokenService` flow. The **refresh operation** is a new client-credentials grant instead of `client.refreshCredentials`. |
| `onAuthChange`, `authState`, `onTokenRefreshed` | Unchanged. |
| `currentUser`, `onUserChange`, `reloadUser()` | Unchanged. Keycloak's userinfo endpoint returns the built-in `service-account-<clientId>` user. This requires `openid` in `scopes`, which the default scopes already include. |
| `logout()` | Clears the local session only. The server revocation call is skipped because there is no refresh token and no browser session to end. |
| `manageAccount()`, `getAccountCredentials()`, `handleWebCallback()` | Throw `UnsupportedError('Not available with GrantType.clientCredentials')`. |

## Internals

### 1. Grant function (`lib/keycloak_client.dart`)

A private method builds the service-account client:

```dart
Future<Client> _clientCredentialsGrant() => clientCredentialsGrant(
  _clientConfig.tokenEndpoint,
  _clientConfig.clientId,
  _clientConfig.clientSecret,
  scopes: _clientConfig.scopes,
  httpClient: _httpClient,        // null in production
);
```

`_login()` calls it instead of the strategy `switch` when
`grantType == clientCredentials`. `_createInternals()` passes
`(_, _) => _clientCredentialsGrant()` to `TokenService` as its `refreshOperation`,
unless a test has already injected one.

For tests, `KeycloakClient.withDependencies` (already `@visibleForTesting`)
gains an optional `http.Client? httpClient`. As a result, `http` moves from
`dev_dependencies` to `dependencies`. It is already a transitive dependency
through `oauth2`.

### 2. Login error mapping

Login errors map the same way `desktop_login_strategy.dart` maps them today:

- `AuthorizationException` (`invalid_client`, `unauthorized_client`, service
  accounts disabled on the client) → `KeycloakServerException(400, e.error)`
- `SocketException` → `KeycloakNetworkException`
- `TimeoutException` (login uses `refreshTimeout`) → `KeycloakTimeoutException`

### 3. No local expiry for the "refresh" side

A service account has no refresh token. Instead, it can always get a new token
while its secret is valid. Its credentials therefore use the same "no local
expiry" path offline tokens already use: `UserCredentials.fromOAuth2(...,
isOfflineToken: true)`, which sets `refreshTokenExpiry = DateTime(9999)`. Without
this, `initialize()` would declare `sessionExpired` 30 days after the last token
was issued.

`ClientConfig.isOfflineSession` keeps its current meaning. The facade and
`TokenService` compute the flag as `isOfflineSession || isServiceAccount`
wherever they build credentials.

### 4. Permanent refresh failures

Today an `AuthorizationException` other than `invalid_grant` is treated as
transient and retried every 30 s forever. In service-account mode,
`invalid_client` and `unauthorized_client` mean the secret was rotated or the
client was reconfigured, and retrying can't fix either one. `TokenService` takes
a new constructor parameter, `Set<String> permanentAuthErrors`, with
`{'invalid_grant'}` as its default. The facade passes
`{'invalid_grant', 'invalid_client', 'unauthorized_client'}` in
service-account mode. Those errors end the session as
`AuthState.sessionExpired`.

Behaviour in authorization-code mode is unchanged.

## Files touched

- `lib/src/enums/grant_type.dart`: new
- `lib/src/models/client_config.dart`: `grantType` field and an
  `isServiceAccount` getter
- `lib/keycloak_client.dart`: export `GrantType`; constructor check; branches in
  `_login`, `logout`, `manageAccount`, `getAccountCredentials` and
  `handleWebCallback`; refresh operation; the offline-flag computation;
  `httpClient` in `withDependencies`
- `lib/src/core/token_service.dart`: `permanentAuthErrors` parameter
- `pubspec.yaml`: move `http` to `dependencies`
- `README.md`: a "Service accounts" section, including a warning that a client
  secret must never ship in a public mobile, web or desktop build
- `CHANGELOG.md`: entry under 4.0.0, released together with required roles

## Testing

Unit tests in `test/` use a mock `http.Client` passed through
`withDependencies`:

1. `login()` posts `grant_type=client_credentials` with the client's
   credentials, never touches a login strategy, and ends in `signedIn` with the
   service-account user.
2. The constructor throws `ArgumentError` when the secret is missing.
3. After the access token expires, `getAuthToken()` issues a new
   client-credentials grant, not a refresh-token grant.
4. `initialize()` restores a stored service-account session older than 30
   days without reporting `sessionExpired`.
5. An `invalid_client` during refresh → `sessionExpired`, with no retry loop.
   The same error in authorization-code mode still retries.
6. `logout()` makes no network call and ends in `signedOut`.
7. `manageAccount()`, `getAccountCredentials()` and `handleWebCallback()` throw
   `UnsupportedError`.
8. Login error mapping: `invalid_client` → `KeycloakServerException`, socket
   error → `KeycloakNetworkException`.

Live test in `test/live/`: a confidential client with "Service accounts
roles" enabled logs in, receives a token and reads `currentUser`.
