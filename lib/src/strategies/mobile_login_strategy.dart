import 'dart:async';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:oauth2/oauth2.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/client_config.dart';
import '../models/keycloak_exception.dart';
import '../models/platform_config.dart';
import '../interfaces/login_strategy.dart';

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
      codeVerifier: _generateCodeVerifier(),
    );

    final redirect = Uri.parse(platformConfig.redirectUri);
    final authUrl = grant.getAuthorizationUrl(
      redirect,
      scopes: clientConfig.scopes,
    );

    if (!await launchUrl(authUrl, mode: LaunchMode.externalApplication)) {
      throw const KeycloakNetworkException(
        'Could not launch browser for login.',
      );
    }

    // Wait for the OS to deliver the deep link back to the app
    final appLinks = AppLinks();
    late final Uri callbackUri;
    try {
      callbackUri = await appLinks.uriLinkStream
          .firstWhere((uri) {
            return uri.toString().startsWith(redirect.toString());
          })
          .timeout(
            platformConfig.deepLinkTimeout,
            onTimeout: () {
              throw const KeycloakTimeoutException(
                'Login timed out waiting for deep link.',
              );
            },
          );
    } on KeycloakTimeoutException {
      rethrow;
    }

    final params = callbackUri.queryParameters;
    if (params.containsKey('error')) return null; // user cancelled

    try {
      return await grant.handleAuthorizationResponse(params);
    } on AuthorizationException catch (e) {
      throw KeycloakServerException(400, e.error);
    }
  }

  String _generateCodeVerifier() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rng = Random.secure();
    return List.generate(64, (_) => chars[rng.nextInt(chars.length)]).join();
  }
}
