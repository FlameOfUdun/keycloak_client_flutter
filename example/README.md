# keycloak_client — Example App

A small Flutter app demonstrating the `keycloak_client` package.

## What it shows

- Restoring a persisted session on startup (`initialize`)
- Reacting to auth state changes via `onAuthChange`, including
  `AuthState.sessionExpired` and `AuthState.accessDenied`
- Displaying user info via `onUserChange`
- Logging in with the system browser (`login`), or as a service account
  (`GrantType.clientCredentials`, no browser)
- Required realm roles (`requiredRealmRoles`): a denied login reports the
  missing roles from `KeycloakAccessDeniedException.missing`
- The principal's realm and client roles (`roles`), re-read on every
  `onTokenRefreshed`, with a button that forces `refreshToken()`
- Token rotation (`onTokenRefreshed`), the account console (`manageAccount`)
  and authentication methods (`getAccountCredentials`)
- Logging out (`logout`)

## Configuration

Everything is passed with `--dart-define`, so `lib/main.dart` needs no edits:

| Define | Default | Meaning |
| --- | --- | --- |
| `KC_BASE_URL` | placeholder | Keycloak server root |
| `KC_REALM` | placeholder | Realm name |
| `KC_CLIENT_ID` | placeholder | OAuth client ID |
| `KC_DESKTOP_REDIRECT` | hosted redirect page | Redirect URI sent to Keycloak on desktop |
| `KC_WEB_REDIRECT` | hosted redirect page | Redirect URI on web |
| `KC_CLIENT_SECRET` | empty | Client secret (required with `KC_SERVICE_ACCOUNT`) |
| `KC_SERVICE_ACCOUNT` | `false` | `true` signs in with the client-credentials grant |
| `KC_REQUIRED_REALM_ROLE` | empty | Realm role the principal must hold |

For mobile and web you must also register the redirect URI on each platform —
see **Platform Setup** in the main [README](../README.md).

## Try it locally

`keycloak/winche-demo-realm.json` is a ready-made realm for Keycloak 26. Start
Keycloak with it from the `example/` directory (PowerShell):

```powershell
docker run --rm --name keycloak-demo -p 8080:8080 `
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin `
  -v "${PWD}\keycloak:/opt/keycloak/data/import" `
  quay.io/keycloak/keycloak:26.6.1 start-dev --import-realm
```

From Git Bash, prefix it with `MSYS_NO_PATHCONV=1` and use
`-v "$(pwd -W)/keycloak:/opt/keycloak/data/import"`. The admin console is at
<http://localhost:8080/admin> (`admin` / `admin`). The realm is imported only
when it does not exist yet; with `--rm` every start is fresh.

If port 8080 is already taken, map another host port (for example
`-p 8090:8080`) and use it in `KC_BASE_URL` below
(`--dart-define=KC_BASE_URL=http://localhost:8090`). Nothing else changes: the
app's loopback redirect stays on port 8765.

Stop Keycloak with `docker stop keycloak-demo`; `--rm` removes the container.

The `winche-demo` realm contains:

| | |
| --- | --- |
| Realm role | `staff` |
| `flutter-app` | Public client, standard flow with PKCE (S256), redirect `http://localhost:8765/callback` |
| `backend-sa` | Confidential client, service accounts only, secret `backend-sa-secret`; its service account holds `staff` |
| `staffer` / `password123` | User with `staff` |
| `outsider` / `password123` | User without `staff` |

Then, from `example/`, run one of these (PowerShell; in Bash replace the
backtick line continuations with `\`):

**1. Browser login** — sign in as `staffer` or `outsider`:

```powershell
flutter run -d windows `
  --dart-define=KC_BASE_URL=http://localhost:8080 `
  --dart-define=KC_REALM=winche-demo `
  --dart-define=KC_CLIENT_ID=flutter-app `
  --dart-define=KC_DESKTOP_REDIRECT=http://localhost:8765/callback
```

**2. Browser login requiring `staff`** — `outsider` is turned away with the
missing roles shown; `staffer` gets in:

```powershell
flutter run -d windows `
  --dart-define=KC_BASE_URL=http://localhost:8080 `
  --dart-define=KC_REALM=winche-demo `
  --dart-define=KC_CLIENT_ID=flutter-app `
  --dart-define=KC_DESKTOP_REDIRECT=http://localhost:8765/callback `
  --dart-define=KC_REQUIRED_REALM_ROLE=staff
```

To see `AuthState.accessDenied`, sign in as `staffer`, remove the `staff` role
from that user in the admin console (*Users → staffer → Role mapping*), then
press the refresh button on the **Roles** card. Waiting for the next scheduled
refresh, or restarting the app once the stored access token has expired
(5 minutes by default), has the same effect.

**3. Service account** — no browser; signs in as `service-account-backend-sa`:

```powershell
flutter run -d windows `
  --dart-define=KC_BASE_URL=http://localhost:8080 `
  --dart-define=KC_REALM=winche-demo `
  --dart-define=KC_CLIENT_ID=backend-sa `
  --dart-define=KC_CLIENT_SECRET=backend-sa-secret `
  --dart-define=KC_SERVICE_ACCOUNT=true `
  --dart-define=KC_REQUIRED_REALM_ROLE=staff
```

`KC_REQUIRED_REALM_ROLE=staff` is optional here. The account console and
authentication methods are hidden in this mode, because `manageAccount()` and
`getAccountCredentials()` are not available to a service account.

> The secret is in this README and the realm file on purpose: it is a local
> demo. Never ship a client secret in a public app build.

The chip on the login screen and in the home app bar shows which mode the app
was started in: **Browser login** or **Service account**. It is a label, not a
control; the mode is fixed by the `--dart-define`s.

Sessions are stored with `flutter_secure_storage`, so the app restores the
last session on the next start. Sign out before switching between the browser
and service-account modes, or the app restores the previous mode's session.

### Running without `flutter run`

`flutter run` keeps the Dart tooling resident, which is memory-hungry. To just
use the app, build it once with the same defines and launch the executable:

```powershell
flutter build windows --debug `
  --dart-define=KC_BASE_URL=http://localhost:8080 `
  --dart-define=KC_REALM=winche-demo `
  --dart-define=KC_CLIENT_ID=flutter-app `
  --dart-define=KC_DESKTOP_REDIRECT=http://localhost:8765/callback
.\build\windows\x64\runner\Debug\keycloak_client_example.exe
```

The defines are compiled in, so rebuild to switch configuration. There is no
hot reload this way.
