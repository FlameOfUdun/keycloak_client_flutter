# keycloak_client

Cross-platform Keycloak authentication for Flutter with:

- Authorization Code + PKCE
- mobile deep links
- desktop loopback callbacks
- web redirect callbacks
- secure credential persistence
- automatic token refresh
- auth and user streams
- typed read of the user's configured authentication methods (password, OTP, WebAuthn)

## Install

```yaml
dependencies:
  keycloak_client: ^2.1.0
```

## Quick Start

```dart
import 'package:keycloak_client/keycloak_client.dart';

final client = KeycloakClient(
  clientConfig: ClientConfig(
    baseUrl: 'https://auth.example.com',
    realm: 'my-realm',
    clientId: 'my-client',
  ),
  // optional — only needed to override defaults
  mobileConfig: MobileConfig(redirectUri: 'myapp://auth'),
  desktopConfig: DesktopConfig(loopbackUri: Uri.parse('http://localhost:8765/callback')),
  webConfig: WebConfig(redirectUri: 'https://example.com/auth/callback'),
);
```

Initialize early:

```dart
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

Login:

```dart
await client.login();
```

Logout:

```dart
await client.logout();
```

Get a valid access token:

```dart
try {
  final token = await client.getAuthToken();
  if (token == null) {
    // No active session — show login screen
  } else {
    // Use token in Authorization header
  }
} on KeycloakNetworkException {
  // Session is valid but device is offline — show offline banner
}
```

## Configuration

Everything is configured through `ClientConfig` and optional per-platform config objects.

```dart
final client = KeycloakClient(
  clientConfig: ClientConfig(
    baseUrl: 'https://auth.example.com',
    realm: 'my-realm',
    clientId: 'my-client',
  ),
  // optional platform overrides
  mobileConfig: MobileConfig(redirectUri: 'myapp://auth'),
  desktopConfig: DesktopConfig(loopbackUri: Uri.parse('http://localhost:8765/callback')),
  webConfig: WebConfig(redirectUri: 'https://example.com/auth/callback'),
);
```

`ClientConfig` fields:

- `baseUrl`: Keycloak server root
- `realm`: Keycloak realm name
- `clientId`: OAuth client ID
- `clientSecret`: for confidential clients only
- `scopes`: defaults to `openid`, `email`, `profile`
- `logLevel`: package logging verbosity
- `refreshTimeout`: HTTP timeout for each token refresh attempt — defaults to `Duration(seconds: 15)`. Lower for faster offline detection; raise for high-latency deployments.

Platform config defaults:

- `MobileConfig.redirectUri`: `myapp://auth`
- `DesktopConfig.redirectUri`: `https://winchetechnologies.co.uk/tools/oauth_redirect`
- `DesktopConfig.loopbackUri`: `http://localhost:8765/callback`
- `WebConfig.redirectUri`: `https://winchetechnologies.co.uk/tools/oauth_redirect`

For desktop, these two values have different jobs:

- `DesktopConfig.redirectUri`: the URI sent to Keycloak
- `DesktopConfig.loopbackUri`: the local URI the desktop app listens on

## Dev Redirect Helper

Recent Keycloak versions can be awkward about using `localhost` as an allowed redirect URI. To make local development easier, this package ships with a public redirect endpoint by default:

`https://winchetechnologies.co.uk/tools/oauth_redirect`

The idea is:

1. Register that public URL in Keycloak as a valid redirect URI.
2. Use that public URL as `DesktopConfig.redirectUri` during desktop dev.
3. Keep `DesktopConfig.loopbackUri` on a local address such as `http://localhost:8765/callback`.
4. Keycloak redirects the browser to the public helper page after login.
5. That page lets the you enter your loopback uri.
6. The page forwards the full callback, including Keycloak query parameters, to the local loopback server.

## Web Startup

Web login is redirect-based. Call `handleWebCallback(Uri.base)` on startup before rendering the app:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (kIsWeb) {
    await client.handleWebCallback(Uri.base);
  }

  runApp(const MyApp());
}
```

On web, `login()` redirects the current tab and does not complete before navigation.

## Account Credentials

Read the authentication methods the current user has configured (password, OTP, WebAuthn, …) from Keycloak's account REST API:

```dart
final credentials = await client.getAccountCredentials();
```

Results are returned as a sealed `AccountCredential` family. Pattern match to access type-specific fields:

```dart
for (final credential in credentials) {
  switch (credential) {
    case PasswordCredential():
      print('Password: ${credential.isConfigured ? 'set' : 'not set'}');
    case OtpCredential(:final instances):
      for (final otp in instances) {
        print('OTP: ${otp.userLabel} (${otp.subType.name}, ${otp.digits} digits)');
      }
    case WebAuthnCredential(:final instances):
      for (final key in instances) {
        print('WebAuthn: ${key.userLabel} (aaguid=${key.aaguid})');
      }
    case UnknownCredential():
      // Realm-specific or future credential provider — inspect raw `credentialData`.
      print('${credential.type}: ${credential.instanceCount} configured');
  }
}
```

Each `AccountCredential` exposes `type`, `category`, `displayName`, `instanceCount`, and `isConfigured`. Per-type instance models carry the common `id` / `userLabel` / `createdDate` plus the fields shown above (OTP `subType`/`digits`/`period`/`algorithm`, WebAuthn `aaguid`). `UnknownCredential` carries the raw `credentialData` map so realm-specific or future providers don't break parsing.

Account credentials are queried on demand and not cached — the source of truth is Keycloak. If your UI needs offline-first reads, memoize the result in your app.

## Streams

Auth state:

```dart
StreamBuilder<AuthState>(
  stream: client.onAuthChange,
  builder: (context, snapshot) {
    final state = snapshot.data ?? AuthState.unknown;
    return Text('$state');
  },
);
```

User info:

```dart
StreamBuilder<UserInfo?>(
  stream: client.onUserChange,
  builder: (context, snapshot) {
    final user = snapshot.data;
    return Text(user?.username ?? 'No user');
  },
);
```

## Platform Setup

## Keycloak

Register the correct redirect URIs in your Keycloak client.

Typical values:

- Android/iOS: `myapp://auth`
- Desktop dev: `https://winchetechnologies.co.uk/tools/oauth_redirect`
- Desktop local listener: `http://localhost:8765/callback`
- Web dev: `https://winchetechnologies.co.uk/tools/oauth_redirect`
- Web prod: your real public web callback URL

For desktop dev with the helper endpoint:

- `redirectUri` is the public URL you register in Keycloak
- `loopbackUri` is the local listener inside your desktop app
- the helper page bridges the public redirect back to the local loopback server

## Android

Add the deep-link intent filter to your `MainActivity` in `android/app/src/main/AndroidManifest.xml`:

```xml
<activity
    android:name=".MainActivity"
    android:exported="true"
    android:launchMode="singleTop">
    <intent-filter>
        <action android:name="android.intent.action.VIEW"/>
        <category android:name="android.intent.category.DEFAULT"/>
        <category android:name="android.intent.category.BROWSABLE"/>
        <data android:scheme="myapp" android:host="auth"/>
    </intent-filter>
</activity>
```

Also ensure internet permission exists:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

Your `MobileConfig.redirectUri` must match the scheme/host you register here.

## iOS

Add your custom scheme to `ios/Runner/Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleTypeRole</key>
    <string>Editor</string>
    <key>CFBundleURLName</key>
    <string>myapp</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>myapp</string>
    </array>
  </dict>
</array>
```

Only the scheme goes in `CFBundleURLSchemes`. For the default
`MobileConfig.redirectUri` of `myapp://auth`, iOS registers `myapp` here and
your Dart config keeps the full redirect URI.

## macOS / Windows / Linux

Desktop login uses a system browser plus a local HTTP listener.

Important fields:

- `DesktopConfig.redirectUri`: the redirect URI sent to Keycloak
- `DesktopConfig.loopbackUri`: the local URI the desktop app listens on (default: `http://localhost:8765/callback`)
- `DesktopConfig.loopbackTimeout`: how long to wait for the callback

The app always listens on `loopbackUri` while Keycloak redirects to `redirectUri`. For local development:

- register `https://winchetechnologies.co.uk/tools/oauth_redirect` in Keycloak
- keep `loopbackUri` on a local port like `http://localhost:8765/callback`
- when the helper page opens, enter that local port so it forwards the callback back to your app

## Web

For local development, you can use the same public helper endpoint:

```dart
web: const WebConfig(
  redirectUri: 'https://winchetechnologies.co.uk/tools/oauth_redirect',
),
```

For production, use your own public callback URL instead.

Always:

- register the web redirect URI in Keycloak
- call `handleWebCallback(Uri.base)` on app startup

## Main API

- `initialize()`: restore any existing session
- `login()`: start authentication
- `handleWebCallback(uri)`: resume a web redirect flow
- `logout()`: clear session and notify Keycloak when possible
- `getAuthToken()`: return a valid access token, `null` if no session, or throw `KeycloakNetworkException` if offline with a valid session
- `refreshToken()`: force an immediate token refresh and user profile reload regardless of token expiry — useful after account management or role changes; throws `KeycloakNetworkException` if offline
- `reloadUser()`: reload profile data from `/userinfo`
- `getAccountCredentials()`: list the user's configured authentication methods as a sealed `AccountCredential` family
- `manageAccount()`: open Keycloak account console in external browser
- `onAuthChange`: stream of `AuthState`
- `onUserChange`: stream of `UserInfo?`

## Auth States

- `AuthState.unknown`
- `AuthState.signedOut`
- `AuthState.signedIn`
- `AuthState.sessionExpired`

## Exceptions

The package throws typed exceptions:

- `KeycloakNetworkException`
- `KeycloakServerException`
- `KeycloakSessionExpiredException`
- `KeycloakTimeoutException`

## Notes

- Call `initialize()` before `login()`, `logout()`, or `reloadUser()`
- Credentials are stored with `flutter_secure_storage`
- User profile data comes from Keycloak's `/userinfo` endpoint
