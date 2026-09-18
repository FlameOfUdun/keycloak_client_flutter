import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:oauth2/oauth2.dart';

import '../models/client_config.dart';
import '../models/keycloak_exception.dart';
import '../models/platform_config.dart';
import '../interfaces/login_strategy.dart';
import '../utilities/pkce.dart';

/// The signature of [FlutterWebAuth2.authenticate], injectable for tests.
typedef WebAuthenticate = Future<String> Function({
  required String url,
  required String callbackUrlScheme,
  FlutterWebAuth2Options options,
});

/// Mobile login in an in-app auth session: `ASWebAuthenticationSession` on
/// iOS, Auth Tab / Custom Tabs on Android.
///
/// The session is shown over the app and hands the callback URL straight back,
/// so there is no deep-link listener, no "Open in app?" prompt and no browser
/// left behind. On Android the consumer registers `flutter_web_auth_2`'s
/// `CallbackActivity` for the redirect scheme; a custom scheme needs no iOS
/// setup.
final class MobileLoginStrategy implements IMobileLoginStrategy {
  final WebAuthenticate _authenticate;
  final http.Client? _httpClient;

  const MobileLoginStrategy() : this.withAuthenticator(FlutterWebAuth2.authenticate);

  /// [httpClient] carries the code exchange, so tests can fake the token
  /// endpoint.
  @visibleForTesting
  const MobileLoginStrategy.withAuthenticator(WebAuthenticate authenticate, {http.Client? httpClient})
    : _authenticate = authenticate,
      _httpClient = httpClient;

  @override
  Future<Client?> login({
    required MobileConfig platformConfig,
    required ClientConfig clientConfig,
  }) async {
    final grant = AuthorizationCodeGrant(
      clientConfig.clientId,
      clientConfig.authorizationEndpoint,
      clientConfig.tokenEndpoint,
      secret: clientConfig.clientSecret,
      codeVerifier: generateCodeVerifier(),
      httpClient: _httpClient,
    );

    final redirect = Uri.parse(platformConfig.redirectUri);
    final authUrl = grant.getAuthorizationUrl(
      redirect,
      scopes: clientConfig.scopes,
      state: generateState(),
    );
    final isHttps = redirect.scheme == 'https';

    final String result;
    try {
      result = await _authenticate(
        url: authUrl.toString(),
        callbackUrlScheme: redirect.scheme,
        options: FlutterWebAuth2Options(
          preferEphemeral: platformConfig.preferEphemeral,
          // flutter_web_auth_2 needs these to match an https (app / universal
          // link) redirect.
          httpsHost: isHttps ? redirect.host : null,
          httpsPath: isHttps ? redirect.path : null,
        ),
      );
    } on PlatformException catch (e) {
      // The sheet was dismissed on iOS, or on Android the user came back to
      // the app without finishing.
      if (e.code == 'CANCELED') return null;
      throw KeycloakNetworkException(e);
    }

    final params = Uri.parse(result).queryParameters;
    final error = params['error'];
    if (error != null) {
      if (error == 'access_denied') return null; // user cancelled
      throw KeycloakServerException(400, error);
    }

    try {
      return await grant.handleAuthorizationResponse(params);
    } on AuthorizationException catch (e) {
      throw KeycloakServerException(400, e.error);
    } on FormatException catch (e) {
      // Raised by oauth2 when the callback's `state` does not match the one
      // sent — a code delivered by someone other than the IdP we redirected to.
      throw KeycloakServerException(400, e.message);
    }
  }
}
