import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:oauth2/oauth2.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/client_config.dart';
import '../models/keycloak_exception.dart';
import '../models/platform_config.dart';
import '../interfaces/login_strategy.dart';
import '../utilities/pkce.dart';

/// Mobile login via system browser + deep link callback.
///
/// The consumer is responsible for:
/// - Setting the correct URI scheme in AndroidManifest.xml and Info.plist
/// - Passing a [redirectUri] that matches the registered scheme,
///   e.g. `myapp://callback`
final class MobileLoginStrategy implements IMobileLoginStrategy {
  const MobileLoginStrategy();

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
    );

    final redirect = Uri.parse(platformConfig.redirectUri);
    final authUrl = grant.getAuthorizationUrl(
      redirect,
      scopes: clientConfig.scopes,
      state: generateState(),
    );

    // Subscribe BEFORE launching the browser. A user already signed in at
    // Keycloak is bounced straight back, and the OS can deliver the deep link
    // before a listener attached afterwards would exist — losing the callback
    // and hanging the login until deepLinkTimeout. The desktop strategy binds
    // its loopback server early for the same reason.
    final appLinks = AppLinks();
    final callback = appLinks.uriLinkStream
        .firstWhere((uri) => uri.toString().startsWith(redirect.toString()))
        .timeout(
          platformConfig.deepLinkTimeout,
          onTimeout: () {
            throw const KeycloakTimeoutException(
              'Login timed out waiting for deep link.',
            );
          },
        );

    if (!await launchUrl(authUrl, mode: LaunchMode.externalApplication)) {
      // Nothing will ever complete this now, and an abandoned future that
      // throws on timeout surfaces as an unhandled async error.
      callback.ignore();
      throw const KeycloakNetworkException(
        'Could not launch browser for login.',
      );
    }

    final callbackUri = await callback;

    final params = callbackUri.queryParameters;
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
