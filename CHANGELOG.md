# CHANGELOG

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
