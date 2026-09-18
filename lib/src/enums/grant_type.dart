/// How [KeycloakClient] obtains its tokens.
enum GrantType {
  /// Interactive Authorization Code + PKCE login in a browser. The default.
  authorizationCode,

  /// OAuth2 client-credentials grant: the client authenticates as its own
  /// Keycloak service account with `clientId` + `clientSecret`. There is no
  /// browser and no human user.
  ///
  /// Requires "Client authentication" and "Service accounts roles" enabled on
  /// the Keycloak client. Never ship the secret in a public app build.
  clientCredentials,
}
