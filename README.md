# keycloak_client

A Flutter package for Keycloak authentication. Handles login, token refresh, session persistence, and user profile — so you don't have to.

[![pub package](https://img.shields.io/pub/v/keycloak_client.svg)](https://pub.dev/packages/keycloak_client)
[![pub points](https://img.shields.io/pub/points/keycloak_client)](https://pub.dev/packages/keycloak_client/score)
[![popularity](https://img.shields.io/pub/popularity/keycloak_client)](https://pub.dev/packages/keycloak_client/score)

---

## Features

- **Browser login** — full Authorization Code flow via the system browser
- **Automatic token refresh** — silently refreshes access tokens before they expire
- **Persistent sessions** — credentials stored securely via `flutter_secure_storage`
- **Reactive auth state** — `Stream<AuthState>` for signed-in / signed-out / session-expired / unknown
- **Reactive user profile** — `Stream<UserInfo?>` that updates whenever user data changes
- **On-demand tokens** — `getAuthToken()` returns a fresh token, refreshing automatically if needed
- **Typed exceptions** — `KeycloakNetworkException`, `KeycloakServerException`, `KeycloakSessionExpiredException` — no raw `DioException` leaks
- **Configurable logging** — from silent to trace-level with structured output

---

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  keycloak_client: ^0.0.1
```

---

## Setup

Create a single `KeycloakClient` instance for your app and call `initialize()` early (e.g. in `initState` or your DI setup). `initialize()` is non-blocking — it restores any persisted session in the background.

```dart
final client = KeycloakClient(
  baseUrl: 'https://auth.example.com',              // Keycloak server URL
  realm: 'my-realm',                                // Keycloak realm name
  clientId: 'my-app',                               // Client ID registered in Keycloak
  redirectUri: 'myapp://auth',                      // Redirect URI registered in Keycloak
  scopes: const ['openid', 'email', 'profile'],     // Optional — these are the defaults
);

@override
void initState() {
  super.initState();
  client.initialize();
}

@override
void dispose() {
  client.dispose();
  super.dispose();
}
```

> **Redirect URI**: Must be registered in your Keycloak client settings. The scheme (e.g. `myapp`) must also be registered as a custom URL scheme on each platform — see **Platform setup** below.

---

## Platform setup

`login()` uses the system browser via `flutter_web_auth_2`. You must register your redirect URI scheme on each platform before it will work.

### Android

Add a `CallbackActivity` to `android/app/src/main/AndroidManifest.xml` inside `<application>`:

```xml
<activity
  android:name="com.linusu.flutter_web_auth_2.CallbackActivity"
  android:exported="true">
  <intent-filter android:label="flutter_web_auth_2">
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="myapp" android:host="auth"/>
  </intent-filter>
</activity>
```

Replace `myapp` with the scheme part of your `redirectUri`.

### iOS

Add your scheme to `ios/Runner/Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>myapp</string>
    </array>
  </dict>
</array>
```

Replace `myapp` with the scheme part of your `redirectUri`.

---

## Usage

### Listening to authentication state

`onAuthChange` emits the current state immediately on subscribe, then on every change.

```dart
StreamBuilder<AuthState>(
  stream: client.onAuthChange,
  builder: (context, snapshot) {
    final state = snapshot.data;

    if (state == null || state.isUnknown) {
      return const CircularProgressIndicator();
    }
    if (state.isSignedIn) {
      return const HomeScreen();
    }
    if (state.isSessionExpired) {
      return const SessionExpiredScreen(); // prompt re-login with a message
    }
    return const LoginScreen();
  },
);
```

| State | Meaning |
| ------- | --------- |
| `AuthState.unknown` | Initial state; session restore in progress |
| `AuthState.signedIn` | User has a valid session |
| `AuthState.signedOut` | User explicitly logged out |
| `AuthState.sessionExpired` | Refresh token expired; user must log in again |

---

### Listening to user changes

`onUserChange` emits the current `UserInfo?` immediately on subscribe, then whenever the profile is updated.

```dart
StreamBuilder<UserInfo?>(
  stream: client.onUserChange,
  builder: (context, snapshot) {
    final user = snapshot.data;
    if (user == null) return const SizedBox.shrink();

    return Text('Hello, ${user.username}');
  },
);
```

**`UserInfo` fields:**

| Field | Type | Scope required | Description |
| ------- | ------ | -------------- | ------------- |
| `id` | `String` | *(always present)* | Keycloak subject (`sub`) |
| `username` | `String?` | `profile` | Preferred username |
| `givenName` | `String?` | `profile` | First name |
| `familyName` | `String?` | `profile` | Last name |
| `email` | `String?` | `email` | Email address |
| `emailVerified` | `bool?` | `email` | Whether the email is verified |

Fields are `null` when the corresponding scope was not requested or the claim was not set on the account.

---

### Login

Opens the system browser for Keycloak's login page and completes the Authorization Code flow automatically.

```dart
await client.login();
// Auth state stream updates to signedIn on success.
```

> Returns without throwing if the user cancels the browser flow.

---

### Logout

Invalidates the session on the Keycloak server and clears local credentials.

```dart
await client.logout();
```

---

### Getting a fresh access token

Use `getAuthToken()` when making authenticated API calls. It returns the current access token, refreshing it automatically if expired.

```dart
final token = await client.getAuthToken();
if (token != null) {
  dio.options.headers['Authorization'] = 'Bearer $token';
}
```

Returns `null` if the user is not signed in or the session has fully expired.

---

### Reloading user profile

Fetches the latest user info from the Keycloak `/userinfo` endpoint and updates the `onUserChange` stream.

```dart
final user = await client.reloadUser();
```

---

## Error handling

`login()` and `reloadUser()` throw typed exceptions — no dependency on Dio internals required.

| Exception | When thrown |
| --------- | ----------- |
| `KeycloakNetworkException` | No connectivity or request timeout |
| `KeycloakServerException` | Keycloak returned an HTTP error (`statusCode` available) |
| `KeycloakSessionExpiredException` | Refresh token expired; user must log in again |

```dart
try {
  await client.login();
} on KeycloakNetworkException {
  // show "check your connection"
} on KeycloakServerException catch (e) {
  // show "server error ${e.statusCode}"
}
```

`getAuthToken()` never throws — it returns `null` when the session is unavailable.

---

## Log Levels

Control log verbosity with the `logLevel` constructor parameter:

```dart
KeycloakClient(
  // ...
  logLevel: LogLevel.info,
);
```

| Level | Description |
| ------- | ------------- |
| `LogLevel.trace` | Everything, including internal state transitions *(default)* |
| `LogLevel.debug` | Debug-level messages |
| `LogLevel.info` | Informational messages (logins, token refreshes) |
| `LogLevel.warning` | Warnings (session expiry, cancelled logins) |
| `LogLevel.error` | Errors only |
| `LogLevel.fatal` | Fatal errors only |
| `LogLevel.off` | Disable all logging |

---

## Disposal

Always call `dispose()` when the client is no longer needed to cancel timers, close streams, and release the HTTP client.

```dart
@override
void dispose() {
  client.dispose();
  super.dispose();
}
```
