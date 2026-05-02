# keycloak_client

Cross-platform Keycloak authentication for Flutter with:

- Authorization Code + PKCE
- mobile deep links
- desktop loopback callbacks
- web redirect callbacks
- secure credential persistence
- automatic token refresh
- auth and user streams

## Install

```yaml
dependencies:
  keycloak_client: ^1.0.0
```

## Quick Start

```dart
import 'package:keycloak_client/keycloak_client.dart';

final client = KeycloakClient(
  config: ClientConfig(
    baseUrl: 'https://auth.example.com',
    realm: 'my-realm',
    clientId: 'my-client',
  ),
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
final token = await client.getAuthToken();
```

## Configuration

Everything is configured through `ClientConfig`.

```dart
final client = KeycloakClient(
  config: ClientConfig(
    baseUrl: 'https://auth.example.com',
    realm: 'my-realm',
    clientId: 'my-client',
    scopes: const ['openid', 'profile', 'email'],
    logLevel: LogLevel.info,
    desktop: const DesktopConfig(),
    mobile: const MobileConfig(),
    web: const WebConfig(),
  ),
);
```

Main fields:

- `baseUrl`: Keycloak server root
- `realm`: Keycloak realm name
- `clientId`: OAuth client ID
- `clientSecret`: for confidential clients only
- `scopes`: defaults to `openid`, `email`, `profile`
- `logLevel`: package logging verbosity

Platform config defaults:

- `MobileConfig.redirectUri`: `myapp://auth`
- `DesktopConfig.redirectUri`: `https://winchetechnologies.co.uk/tools/oauth_redirect`
- `DesktopConfig.loopbackUri`: `http://localhost:8765/callback`
- `WebConfig.redirectUri`: `https://winchetechnologies.co.uk/tools/oauth_redirect`

For desktop, these two values have different jobs:

- `DesktopConfig.redirectUri`: the URI sent to Keycloak
- `DesktopConfig.loopbackUri`: the local URI the desktop app listens on

If `loopbackUri` is `null`, the local desktop listener binds directly to
`redirectUri`.

## Dev Redirect Helper

Recent Keycloak versions can be awkward about using `localhost` as an allowed redirect URI. To make local development easier, this package ships with a public redirect endpoint by default:

`https://winchetechnologies.co.uk/tools/oauth_redirect`

The idea is:

1. Register that public URL in Keycloak as a valid redirect URI.
2. Use that public URL as `DesktopConfig.redirectUri` during desktop dev.
3. Keep `DesktopConfig.loopbackUri` on a local address such as `http://localhost:8765/callback`.
4. Keycloak redirects the browser to the public helper page after login.
5. That page lets the user enter their local port.
6. The page forwards the full callback, including Keycloak query parameters, to the local loopback server.

This is especially convenient for:

- desktop development, where your app is listening on a local loopback URL
- web development, where you want a simple public callback during local work

Desktop default dev setup:

```dart
final client = KeycloakClient(
  config: ClientConfig(
    baseUrl: 'https://auth.example.com',
    realm: 'my-realm',
    clientId: 'my-client',
    desktop: const DesktopConfig(
      redirectUri: 'https://winchetechnologies.co.uk/tools/oauth_redirect',
      loopbackUri: 'http://localhost:8765/callback',
    ),
  ),
);
```

This desktop split is intentional:

- `redirectUri` bypasses Keycloak's localhost restriction
- `loopbackUri` is where the desktop app actually receives the callback

Web default dev setup:

```dart
final client = KeycloakClient(
  config: ClientConfig(
    baseUrl: 'https://auth.example.com',
    realm: 'my-realm',
    clientId: 'my-client',
    web: const WebConfig(
      redirectUri: 'https://winchetechnologies.co.uk/tools/oauth_redirect',
    ),
  ),
);
```

If you already have your own public callback page, you can replace these defaults with your own URLs.

If you are using a real endpoint and do not need the localhost workaround,
prefer setting `loopbackUri` to `null`. In that case, the desktop strategy
binds the local loopback server to `redirectUri` itself.

Example:

```dart
final client = KeycloakClient(
  config: ClientConfig(
    baseUrl: 'https://auth.example.com',
    realm: 'my-realm',
    clientId: 'my-client',
    desktop: const DesktopConfig(
      redirectUri: 'https://your-domain.example.com/auth/callback',
      loopbackUri: null,
    ),
  ),
);
```

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

Do not register `net.openid.appauth.RedirectUriReceiverActivity` unless your app is actually using AppAuth. This package uses `app_links` for mobile deep-link callbacks, so the redirect should reopen your app activity directly.

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
- `DesktopConfig.loopbackUri`: optional separate local listener URI
- `DesktopConfig.loopbackTimeout`: how long to wait for the callback

Behavior:

- if `loopbackUri` is set, the app listens on `loopbackUri` while Keycloak uses `redirectUri`
- if `loopbackUri` is `null`, the app listens directly on `redirectUri`

For local development, the easiest setup is:

- register `https://winchetechnologies.co.uk/tools/oauth_redirect` in Keycloak
- keep `loopbackUri` on a local port like `http://localhost:8765/callback`
- when the helper page opens, enter that local port so it forwards the callback back to your app

For real endpoint setups, prefer:

- `redirectUri`: your real callback URL
- `loopbackUri: null`

That avoids splitting the two values when you do not need the localhost workaround.

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
- `getAuthToken()`: return a valid access token or `null`
- `reloadUser()`: reload profile data from `/userinfo`
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
