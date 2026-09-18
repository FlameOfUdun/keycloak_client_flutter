# Roles and required roles — design

**Date:** 2026-09-18
**Status:** Approved in conversation, awaiting spec review
**Builds on:** `2026-09-18-service-account-mode-design.md`, which must be
implemented first. This design reuses its `httpClient` test seam and
`isServiceAccount`.

## Goal

1. Expose the signed-in principal's Keycloak **roles** (realm and client roles).
2. Let an app declare roles it **requires**. A principal without them never
   becomes `signedIn`, and loses the session if a role is revoked later.

This works the same for users and for service accounts.

## Non-goals

- Keycloak Authorization Services permissions (UMA / RPT). That is a separate,
  later spec, which adds `getPermissions()` on top of this one.
- Verifying the token signature. The token comes directly from the token
  endpoint over TLS, and the check controls UX only. APIs must still enforce
  roles server-side.
- "Any of" role logic. Every required role must be present.

## Where roles come from

Keycloak's access token (a JWT) carries them by default:

```json
"realm_access":    { "roles": ["staff", "default-roles-my-realm"] },
"resource_access": { "my-client": { "roles": ["editor"] } }
```

The library decodes the payload locally, with no network call. If the token
can't be decoded, or the claims are absent or malformed, the result is **no
roles**. That makes the required-role check fail closed.

## Public API

### `KeycloakRoles` (new, exported)

```dart
final class KeycloakRoles {
  final Set<String> realm;
  final Map<String, Set<String>> client;   // clientId → roles
  const KeycloakRoles({this.realm = const {}, this.client = const {}});
  factory KeycloakRoles.fromAccessToken(String accessToken);
  bool hasRealmRole(String role);
  bool hasClientRole(String clientId, String role);
  bool get isEmpty;
}
```

### `ClientConfig` (two new optional fields and one method)

```dart
final Set<String> requiredRealmRoles;                 // default const {}
final Map<String, Set<String>> requiredClientRoles;   // default const {}
KeycloakRoles missingRoles(KeycloakRoles granted);    // empty = all present
```

### `KeycloakClient`

```dart
KeycloakRoles? get roles;   // null while no session
```

The value updates on login, restore and every refresh. Consumers that care
about changes already have `onTokenRefreshed`.

### `AuthState.accessDenied` (new) and `isAccessDenied`

This is a **breaking change** for exhaustive `switch`es over `AuthState`, so
the release is **4.0.0**.

### `KeycloakAccessDeniedException` (new)

```dart
final class KeycloakAccessDeniedException extends KeycloakException {
  final KeycloakRoles missing;
}
```

## Behaviour

| Moment | All required roles present | A required role missing |
|---|---|---|
| `login()` / `handleWebCallback()` | As today; `roles` is set | Server session revoked, nothing left stored, state returns to `signedOut`, and it throws `KeycloakAccessDeniedException(missing)` |
| `initialize()` restoring a session | As today; `roles` is set | Server session revoked, store cleared, state `accessDenied` |
| Token refresh (timer, `getAuthToken()`, `refreshToken()`) | `roles` updated; `onTokenRefreshed` emits | Server session revoked, store cleared, state `accessDenied`. `getAuthToken()` returns `null`. `refreshToken()` throws `KeycloakAccessDeniedException`. `onTokenRefreshed` does not emit. |
| `logout()` / any session end | `roles` becomes `null` | — |

On a restore with a transient refresh failure (offline start), the check runs
on the stored token, consistent with the existing offline-first restore.

With no required roles configured, nothing changes except that `roles` is now
exposed.

"Server session revoked" uses the existing `TokenService.revokeSession`, and it
is skipped in service-account mode as `logout()` already does.

## Units

- `lib/src/models/keycloak_roles.dart`: decoding and helpers. Pure.
- `lib/src/models/client_config.dart`: the fields and `missingRoles`.
- `lib/src/enums/auth_state.dart`: `accessDenied`.
- `lib/src/models/keycloak_exception.dart`: the new exception.
- `lib/keycloak_client.dart`: the `roles` getter; a pure `_checkRoles(token)`
  that returns what's missing and records `roles` when nothing is; a shared
  `_revokeServerSession()` extracted from `logout()`; and the checks at the
  three moments above.
- `example/lib/main.dart`: handle `accessDenied` in its `AuthState` switch.

## Testing

- `KeycloakRoles`: realm and client parsing; missing claims; a malformed token;
  wrong claim types; the helpers.
- `ClientConfig.missingRoles`: all present, realm missing, client missing, and
  an unknown client.
- `KeycloakClient`:
  - login with the roles → `signedIn` and `roles` exposed;
  - login without them → throws, `signedOut`, store empty, `/logout` called;
  - restore without them → `accessDenied`;
  - a refresh that loses a role → `getAuthToken()` is `null` and the state is
    `accessDenied`;
  - no requirements → a role-less user signs in;
  - `logout()` clears `roles`.
