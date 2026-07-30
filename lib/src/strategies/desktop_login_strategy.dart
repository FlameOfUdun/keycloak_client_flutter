import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:oauth2/oauth2.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/client_config.dart';
import '../models/keycloak_exception.dart';
import '../models/platform_config.dart';
import '../interfaces/login_strategy.dart';
import '../utilities/pkce.dart';

/// Desktop login via localhost HttpServer + system browser.
/// Works on Windows, macOS, and Linux.
final class DesktopLoginStrategy implements IDesktopLoginStrategy {
  static const _defaultSuccessPageHtml = '''
<!DOCTYPE html><html><head><meta charset="utf-8">
<title>Authentication complete</title>
<style>
  body{font-family:-apple-system,sans-serif;display:flex;align-items:center;
       justify-content:center;height:100vh;margin:0;background:#f0f4f8}
  .card{text-align:center;padding:40px;background:#fff;border-radius:12px;
        box-shadow:0 4px 24px rgba(0,0,0,.08)}
  h1{color:#1a7f64;font-size:22px;margin-bottom:8px}
  p{color:#555;font-size:14px}
</style></head>
<body><div class="card">
  <h1>Authentication successful</h1>
  <p>You may close this window and return to the app.</p>
</div></body></html>''';

  @override
  Future<Client?> login({
    required DesktopConfig platformConfig,
    required ClientConfig clientConfig,
  }) async {
    final loopback = Uri.parse(platformConfig.loopbackUri);
    final host = loopback.host.isEmpty
        ? InternetAddress.loopbackIPv4.address
        : loopback.host;
    final port = loopback.port == 0 ? 8765 : loopback.port;
    final expectedPath = loopback.path.isEmpty ? '/' : loopback.path;

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

    // Bind the loopback server BEFORE launching the browser so the IdP's
    // redirect cannot arrive before we are listening (e.g. when the user
    // is already signed in at Keycloak and the round-trip is instant).
    //
    // The loopback port is open to anything running on this machine, so the
    // `state` above is what makes a code arriving here trustworthy: oauth2
    // rejects the exchange when it does not match.
    final HttpServer server;
    try {
      server = await HttpServer.bind(host, port);
    } on SocketException catch (e) {
      throw KeycloakNetworkException(
        'Could not bind the login listener on $host:$port — '
        'another process may already hold it. ($e)',
      );
    }

    if (!await launchUrl(authUrl, mode: LaunchMode.externalApplication)) {
      await server.close();
      throw const KeycloakNetworkException(
        'Could not launch browser for login.',
      );
    }

    late final HttpRequest callbackRequest;
    try {
      callbackRequest = await server
          .firstWhere(
            (request) {
              return request.uri.path == expectedPath &&
                  (request.uri.queryParameters.containsKey('code') ||
                      request.uri.queryParameters.containsKey('error'));
            },
            orElse: () {
              throw const KeycloakTimeoutException(
                'Login timed out waiting for browser redirect.',
              );
            },
          )
          .timeout(
            platformConfig.loopbackTimeout,
            onTimeout: () {
              throw const KeycloakTimeoutException(
                'Login timed out waiting for browser redirect.',
              );
            },
          );
    } finally {
      await server.close();
    }

    callbackRequest.response
      ..statusCode = 200
      ..headers.set('Content-Type', 'text/html; charset=utf-8')
      ..add(
        utf8.encode(platformConfig.successPageHtml ?? _defaultSuccessPageHtml),
      );
    await callbackRequest.response.close();

    final params = callbackRequest.uri.queryParameters;

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
      // sent — a code posted to the loopback port by something other than the
      // browser we launched.
      throw KeycloakServerException(400, e.message);
    }
  }
}
