# keycloak_client — Example App

A minimal Flutter app demonstrating the `keycloak_client` package.

## What it shows

- Restoring a persisted session on startup (`initialize`)
- Reacting to auth state changes via `onAuthChange`
- Displaying user info via `onUserChange`
- Logging in with the system browser (`login`)
- Logging out (`logout`)

## How to configure

Before running, open `lib/main.dart` and replace the four placeholder values in `KeycloakClientConfig` with your own Keycloak server details:

```dart
final client = KeycloakClient(
  config: KeycloakClientConfig(
    baseUrl: 'your-keycloak-server',
    clientId: 'your-client-id',
    realm: 'your-realm',
    redirectUri: 'yourapp://auth/callback',
  ),
);
```

You must also register the redirect URI scheme on each platform — see the **Platform setup** section in the main [README](../README.md).

## Running

```sh
flutter run
```
