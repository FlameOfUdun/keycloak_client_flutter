// Drives the FULL desktop authorization-code + PKCE flow against a real
// Keycloak, with only the browser faked out.
//
// Everything else is real: the loopback listener, the authorization URL we
// build, Keycloak's login form, the redirect back, and the code exchange. That
// is what makes this the only test able to prove the `state` parameter is sent
// and round-trips — a mocked token endpoint would accept anything.
//
// Needs the same realm as keycloak_live_test.dart, plus
// `http://localhost:8765/callback` in the client's redirect URIs and a second
// user `tester-desktop` / `password123`. Skips when nothing is listening on
// 8080.
//
// ignore_for_file: avoid_print — progress output is the point of this file.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:keycloak_client/src/models/client_config.dart';
import 'package:keycloak_client/src/models/platform_config.dart';
import 'package:keycloak_client/src/strategies/desktop_login_strategy.dart';
import 'package:mocktail/mocktail.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

const _baseUrl = 'http://localhost:8080';
const _realm = 'winche-test';
const _clientId = 'flutter-app';
const _loopback = 'http://localhost:8765/callback';

/// A user of its own, not the one keycloak_live_test.dart uses.
///
/// Test files run concurrently, and that file logs sessions out. Sharing an
/// identity let it kill a session this one was in the middle of using, which
/// showed up as either suite failing at random.
const _username = 'tester-desktop';

/// Stands in for the system browser: records the URL instead of opening it.
final class FakeUrlLauncher extends Mock
    with MockPlatformInterfaceMixin
    implements UrlLauncherPlatform {
  final urls = <String>[];

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    urls.add(url);
    return true;
  }

  @override
  Future<bool> canLaunch(String url) async => true;
}

Future<bool> serverIsUp() async {
  try {
    final socket = await Socket.connect('localhost', 8080,
        timeout: const Duration(seconds: 2));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Plays the part of the browser: fetches Keycloak's login page, submits the
/// credentials, and follows the redirect back to the loopback listener.
///
/// Written against raw HTTP rather than a browser driver so it runs anywhere,
/// which means carrying Keycloak's session cookies by hand.
Future<void> completeLoginInBrowser(String authUrl) async {
  final client = http.Client();
  try {
    final page = await client.get(Uri.parse(authUrl));
    if (page.statusCode != 200) {
      throw StateError('auth page returned ${page.statusCode}');
    }

    final action = RegExp(r'action="([^"]+)"').firstMatch(page.body)?.group(1);
    if (action == null) throw StateError('no login form in the auth page');
    final formUrl = Uri.parse(action.replaceAll('&amp;', '&'));

    final cookies = page.headers['set-cookie'];
    final submit = await client.post(
      formUrl,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        if (cookies != null) 'Cookie': _cookieHeader(cookies),
      },
      body: {'username': _username, 'password': 'password123'},
    );

    if (submit.statusCode != 302) {
      throw StateError('login POST returned ${submit.statusCode}, expected a redirect');
    }
    final location = submit.headers['location'];
    if (location == null) throw StateError('no redirect after login');

    // Hitting this is what hands the code to the strategy's loopback server.
    await client.get(Uri.parse(location));
  } finally {
    client.close();
  }
}

/// Reduces a raw `set-cookie` header to the `name=value` pairs a request needs.
String _cookieHeader(String setCookie) => setCookie
    .split(RegExp(r',(?=[^;]+?=)'))
    .map((c) => c.split(';').first.trim())
    .where((c) => c.contains('='))
    .join('; ');

void main() {
  late FakeUrlLauncher launcher;

  setUp(() {
    // TestWidgetsFlutterBinding answers every HTTP request with 400 and never
    // touches the network — which would make this suite "pass" against a stub.
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;

    launcher = FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;
  });

  test('completes a real authorization-code flow, state and all', () async {
    if (!await serverIsUp()) {
      markTestSkipped('no Keycloak on localhost:8080 — see this file\'s header');
      return;
    }

    final strategy = DesktopLoginStrategy();
    final login = strategy.login(
      platformConfig: const DesktopConfig(
        redirectUri: _loopback,
        loopbackUri: _loopback,
        loopbackTimeout: Duration(seconds: 30),
      ),
      clientConfig: ClientConfig(
        baseUrl: _baseUrl,
        realm: _realm,
        clientId: _clientId,
      ),
    );

    // Give login() a moment to bind the listener and "open the browser".
    await Future.delayed(const Duration(milliseconds: 300));
    expect(launcher.urls, hasLength(1), reason: 'no browser launch was attempted');

    final authUrl = Uri.parse(launcher.urls.single);
    final sentState = authUrl.queryParameters['state'];

    expect(sentState, isNotNull,
        reason: 'the desktop flow sent no state parameter');
    expect(authUrl.queryParameters['code_challenge'], isNotNull,
        reason: 'PKCE challenge missing');
    expect(authUrl.queryParameters['code_challenge_method'], 'S256');
    print('  [ok] auth URL carries state=$sentState and an S256 PKCE challenge');

    await completeLoginInBrowser(authUrl.toString());

    final client = await login;
    expect(client, isNotNull, reason: 'the code exchange produced no client');
    expect(client!.credentials.accessToken, isNotEmpty);
    expect(client.credentials.refreshToken, isNotNull);
    print('  [ok] exchanged the code for real tokens over the loopback listener');

    client.close();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('rejects a callback whose state does not match', () async {
    if (!await serverIsUp()) {
      markTestSkipped('no Keycloak on localhost:8080');
      return;
    }

    // The point of the fix: before it, no state was sent, so oauth2 had nothing
    // to compare against and a code delivered by anything on this machine was
    // exchanged without question.
    final strategy = DesktopLoginStrategy();
    final login = strategy.login(
      platformConfig: const DesktopConfig(
        redirectUri: _loopback,
        loopbackUri: _loopback,
        loopbackTimeout: Duration(seconds: 30),
      ),
      clientConfig: ClientConfig(
        baseUrl: _baseUrl,
        realm: _realm,
        clientId: _clientId,
      ),
    );

    // Turn a rejection into a value straight away. Nothing awaits `login`
    // until the end of this test, and it rejects the moment the bad callback
    // lands — an unawaited rejection is reported as an uncaught error and
    // fails the test even though the outcome is exactly what we want.
    final outcome = login.then<Object?>((v) => v, onError: (Object e) => e);

    await Future.delayed(const Duration(milliseconds: 300));

    // An attacker cannot know the state, so this is what their callback looks
    // like: a plausible code and a wrong (here, guessed) state.
    await http
        .get(Uri.parse('$_loopback?code=injected-code&state=wrong-state'))
        .catchError((_) => http.Response('', 500));

    // Asserting on the *reason*, not just that it failed. Without a state to
    // compare, the injected code is sent to Keycloak and rejected there — so
    // the flow fails either way, and only the message distinguishes "refused
    // locally, nothing exchanged" from "asked the server about an attacker's
    // code".
    expect(
      await outcome,
      isA<Exception>()
          .having((e) => e.toString(), 'message', contains('state')),
    );
    print('  [ok] a mismatched state is refused before any exchange');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
