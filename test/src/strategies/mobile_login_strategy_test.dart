import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:keycloak_client/keycloak_client.dart';
import 'package:keycloak_client/src/strategies/mobile_login_strategy.dart';

const _config = ClientConfig(baseUrl: 'http://localhost', realm: 'test', clientId: 'app');

/// Stands in for FlutterWebAuth2.authenticate: records the call and answers
/// with [respond], which receives the `state` the strategy sent.
final class FakeAuthSession {
  final String Function(String state) respond;
  final Object? throws;

  String? url;
  String? callbackUrlScheme;
  FlutterWebAuth2Options? options;

  FakeAuthSession(this.respond, {this.throws});

  Future<String> authenticate({
    required String url,
    required String callbackUrlScheme,
    FlutterWebAuth2Options options = const FlutterWebAuth2Options(),
  }) async {
    this.url = url;
    this.callbackUrlScheme = callbackUrlScheme;
    this.options = options;
    if (throws != null) throw throws!;
    return respond(Uri.parse(url).queryParameters['state']!);
  }
}

void main() {
  late List<http.Request> tokenRequests;
  late http.Client tokenEndpoint;

  setUp(() {
    tokenRequests = [];
    tokenEndpoint = MockClient((request) async {
      tokenRequests.add(request);
      return http.Response(
        jsonEncode({'access_token': 'at', 'token_type': 'Bearer', 'expires_in': 300, 'refresh_token': 'rt'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  });

  Future<dynamic> login(FakeAuthSession session, [MobileConfig config = const MobileConfig()]) =>
      MobileLoginStrategy.withAuthenticator(session.authenticate, httpClient: tokenEndpoint)
          .login(platformConfig: config, clientConfig: _config);

  test('exchanges the returned code with the PKCE verifier', () async {
    final session = FakeAuthSession((state) => 'myapp://auth?code=abc&state=$state');

    final client = await login(session);

    expect(client.credentials.accessToken, 'at');
    expect(Uri.parse(session.url!).queryParameters['code_challenge'], isNotEmpty);
    final exchange = tokenRequests.single.bodyFields;
    expect(exchange['grant_type'], 'authorization_code');
    expect(exchange['code'], 'abc');
    expect(exchange['code_verifier'], hasLength(64));
  });

  test('runs a private session for the redirect scheme by default', () async {
    final session = FakeAuthSession((state) => 'myapp://auth?code=abc&state=$state');

    await login(session);

    expect(session.callbackUrlScheme, 'myapp');
    expect(session.options!.preferEphemeral, isTrue);
    expect(session.options!.httpsHost, isNull);
  });

  test('preferEphemeral false is passed through', () async {
    final session = FakeAuthSession((state) => 'myapp://auth?code=abc&state=$state');

    await login(session, const MobileConfig(preferEphemeral: false));

    expect(session.options!.preferEphemeral, isFalse);
  });

  test('an https redirect passes its host and path', () async {
    final session = FakeAuthSession((state) => 'https://app.example.com/auth/callback?code=abc&state=$state');

    await login(session, const MobileConfig(redirectUri: 'https://app.example.com/auth/callback'));

    expect(session.callbackUrlScheme, 'https');
    expect(session.options!.httpsHost, 'app.example.com');
    expect(session.options!.httpsPath, '/auth/callback');
  });

  test('a dismissed session is a cancellation', () async {
    final session = FakeAuthSession((_) => '', throws: PlatformException(code: 'CANCELED'));

    expect(await login(session), isNull);
    expect(tokenRequests, isEmpty);
  });

  test('access_denied is a cancellation', () async {
    final session = FakeAuthSession((state) => 'myapp://auth?error=access_denied&state=$state');

    expect(await login(session), isNull);
  });

  test('any other IdP error is a server error', () async {
    final session = FakeAuthSession((state) => 'myapp://auth?error=server_error&state=$state');

    await expectLater(login(session), throwsA(isA<KeycloakServerException>()));
  });

  test('a callback with a foreign state is rejected', () async {
    final session = FakeAuthSession((_) => 'myapp://auth?code=abc&state=forged');

    await expectLater(login(session), throwsA(isA<KeycloakServerException>()));
    expect(tokenRequests, isEmpty, reason: 'a forged code was exchanged');
  });

  test('a session that cannot start is a network error', () async {
    final session = FakeAuthSession((_) => '', throws: PlatformException(code: 'EXTRA_PARAMETERS_ERROR'));

    await expectLater(login(session), throwsA(isA<KeycloakNetworkException>()));
  });
}
