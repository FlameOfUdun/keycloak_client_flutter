import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:keycloak_client/keycloak_client.dart';

class MockStore extends Mock implements IAuthCredentialsStore {}

/// A store that actually remembers what was written.
///
/// The rotation tests need this: a refresh writes fresh credentials and the
/// very next read has to see them. A mock returning a fixed expired value would
/// make every read trigger another refresh, so the emission counts would
/// measure the fake rather than the client.
final class FakeStore implements IAuthCredentialsStore {
  UserCredentials? creds;
  UserInfo? user;

  FakeStore({this.creds, this.user});

  @override
  Future<UserCredentials?> getCredentials() async => creds;

  @override
  Future<void> setCredentials(UserCredentials? data) async => creds = data;

  @override
  Future<UserInfo?> getUser() async => user;

  @override
  Future<void> setUser(UserInfo? value) async => user = value;

  @override
  Future<void> clear() async {
    creds = null;
    user = null;
  }
}

/// Shared state for the two strategy fakes below.
///
/// A login that stays in flight until released, standing in for the window
/// where a real desktop strategy is holding the loopback port open.
final class LoginProbe {
  var calls = 0;
  var completer = Completer<oauth2.Client?>();

  Future<oauth2.Client?> record() {
    calls++;
    return completer.future;
  }
}

// Both are supplied because which one is used depends on defaultTargetPlatform,
// and flutter_test pins that to android — so a desktop-only fake is silently
// ignored and the real mobile strategy runs instead.
final class SlowDesktopStrategy implements IDesktopLoginStrategy {
  final LoginProbe probe;
  SlowDesktopStrategy(this.probe);

  @override
  Future<oauth2.Client?> login({
    required DesktopConfig platformConfig,
    required ClientConfig clientConfig,
  }) => probe.record();
}

final class SlowMobileStrategy implements IMobileLoginStrategy {
  final LoginProbe probe;
  SlowMobileStrategy(this.probe);

  @override
  Future<oauth2.Client?> login({
    required MobileConfig platformConfig,
    required ClientConfig clientConfig,
  }) => probe.record();
}

UserCredentials _creds({required bool accessExpired}) => UserCredentials(
  accessToken: accessExpired ? 'stale-access' : 'fresh-access',
  refreshToken: 'valid-refresh',
  accessTokenExpiry: accessExpired
      ? DateTime.now().subtract(const Duration(hours: 1))
      : DateTime.now().add(const Duration(minutes: 5)),
  refreshTokenExpiry: DateTime.now().add(const Duration(days: 30)),
);

oauth2.Client _refreshedClient() => oauth2.Client(
  oauth2.Credentials(
    'rotated-access',
    refreshToken: 'valid-refresh',
    expiration: DateTime.now().add(const Duration(minutes: 5)),
    tokenEndpoint: Uri.parse('http://localhost/token'),
  ),
);

void main() {
  late MockStore store;

  setUpAll(() {
    registerFallbackValue(
      UserCredentials(
        accessToken: 'a',
        refreshToken: 'r',
        accessTokenExpiry: DateTime.now().add(const Duration(minutes: 5)),
        refreshTokenExpiry: DateTime.now().add(const Duration(days: 30)),
      ),
    );
  });

  setUp(() {
    store = MockStore();
  });

  group('initialize()', () {
    test('calls refreshOperation exactly once when access token is expired and '
        'server is offline', () async {
      const refreshTimeout = Duration(milliseconds: 100);
      // Allow well more than 2 × refreshTimeout so any double-call bug can manifest.
      const settleDuration = Duration(milliseconds: 350);

      // Credentials: access expired, refresh still valid
      final storedCreds = UserCredentials(
        accessToken: 'old-access',
        refreshToken: 'valid-refresh',
        accessTokenExpiry: DateTime.now().subtract(const Duration(hours: 1)),
        refreshTokenExpiry: DateTime.now().add(const Duration(days: 30)),
      );
      final storedUser = const UserInfo(id: 'u1');

      when(() => store.getCredentials()).thenAnswer((_) async => storedCreds);
      when(() => store.getUser()).thenAnswer((_) async => storedUser);

      var refreshCallCount = 0;

      final client = KeycloakClient.withDependencies(
        clientConfig: ClientConfig(
          baseUrl: 'http://localhost',
          realm: 'test',
          clientId: 'app',
          refreshTimeout: refreshTimeout,
        ),
        credentialsStorage: store,
        tokenRefreshOperation: (_, _) {
          refreshCallCount++;
          return Completer<oauth2.Client>().future; // never resolves → timeout
        },
      );

      await client.waitForInitialization();
      // Wait for any async fire-and-forget ops (e.g. _reloadUser().ignore()) to complete.
      // With refreshTimeout=100ms, a second call would finish within 200ms.
      await Future.delayed(settleDuration);

      expect(
        refreshCallCount,
        1,
        reason:
            'Double-timeout bug: refreshOperation called more than once during initialize()',
      );

      client.dispose();
    });
  });

  group('login()', () {
    test('a second call joins the first instead of starting another', () async {
      // A double-tap used to start a second flow. On desktop that cannot work:
      // the first attempt's loopback listener holds its port for the whole
      // loopbackTimeout, so binding again throws and the click surfaces as an
      // unhandled exception on top of a login that was working fine.
      final probe = LoginProbe();
      final client = KeycloakClient.withDependencies(
        clientConfig: ClientConfig(
          baseUrl: 'http://localhost',
          realm: 'test',
          clientId: 'app',
        ),
        credentialsStorage: FakeStore(),
        desktopLoginStrategy: SlowDesktopStrategy(probe),
        mobileLoginStrategy: SlowMobileStrategy(probe),
      );

      final first = client.login();
      final second = client.login();
      await Future.delayed(const Duration(milliseconds: 50));

      expect(probe.calls, 1, reason: 'a second login flow was started');

      probe.completer.complete(null); // user cancelled
      await Future.wait([first, second]);
      expect(probe.calls, 1);

      client.dispose();
    });

    test('a later call starts a fresh attempt once the first settles',
        () async {
      // The guard must release, or a cancelled login would lock the user out
      // of ever retrying.
      final probe = LoginProbe();
      final client = KeycloakClient.withDependencies(
        clientConfig: ClientConfig(
          baseUrl: 'http://localhost',
          realm: 'test',
          clientId: 'app',
        ),
        credentialsStorage: FakeStore(),
        desktopLoginStrategy: SlowDesktopStrategy(probe),
        mobileLoginStrategy: SlowMobileStrategy(probe),
      );

      final first = client.login();
      probe.completer.complete(null);
      await first;

      probe.completer = Completer<oauth2.Client?>();
      final second = client.login();
      await Future.delayed(const Duration(milliseconds: 50));

      expect(probe.calls, 2, reason: 'the guard never released');

      probe.completer.complete(null);
      await second;
      client.dispose();
    });
  });

  group('refreshToken()', () {
    test('throws KeycloakSessionExpiredException when the session is dead',
        () async {
      // Previously this returned normally on a permanent failure, so an awaiting
      // caller could not tell "refreshed" from "your session just died" without
      // watching onAuthChange.
      final store = FakeStore(
        creds: _creds(accessExpired: false),
        user: const UserInfo(id: 'u1'),
      );
      final client = KeycloakClient.withDependencies(
        clientConfig: ClientConfig(
          baseUrl: 'http://localhost',
          realm: 'test',
          clientId: 'app',
        ),
        credentialsStorage: store,
        tokenRefreshOperation: (_, _) async =>
            throw oauth2.AuthorizationException('invalid_grant', null, null),
      );

      await client.waitForInitialization();

      await expectLater(
        client.refreshToken(),
        throwsA(isA<KeycloakSessionExpiredException>()),
      );
      expect(client.authState, AuthState.sessionExpired);

      client.dispose();
    });
  });

  group('offline sessions', () {
    test('an offline_access session is stored without a local expiry',
        () async {
      final store = FakeStore(
        creds: _creds(accessExpired: true),
        user: const UserInfo(id: 'u1'),
      );
      final client = KeycloakClient.withDependencies(
        clientConfig: ClientConfig(
          baseUrl: 'http://localhost',
          realm: 'test',
          clientId: 'app',
          scopes: const ['openid', 'offline_access'],
        ),
        credentialsStorage: store,
        tokenRefreshOperation: (_, _) async => _refreshedClient(),
      );

      await client.waitForInitialization();

      expect(store.creds!.isOfflineToken, isTrue);
      expect(store.creds!.isRefreshExpired, isFalse);

      client.dispose();
    });
  });

  group('onTokenRefreshed', () {
    KeycloakClient build(FakeStore store, {int? refreshCount}) =>
        KeycloakClient.withDependencies(
          clientConfig: ClientConfig(
            baseUrl: 'http://localhost',
            realm: 'test',
            clientId: 'app',
          ),
          credentialsStorage: store,
          tokenRefreshOperation: (_, _) async => _refreshedClient(),
        );

    test('stays silent for the refresh initialize() runs before the session '
        'begins', () async {
      // A cold start with an expired access token refreshes *before*
      // beginSession. Emitting there would have consumers re-dial for a session
      // that does not exist yet; the session that follows is announced on
      // onAuthChange and onUserChange instead.
      final store = FakeStore(
        creds: _creds(accessExpired: true),
        user: const UserInfo(id: 'u1'),
      );
      final client = build(store);

      final seen = <void>[];
      final sub = client.onTokenRefreshed.listen(seen.add);

      await client.waitForInitialization();
      await Future.delayed(const Duration(milliseconds: 200));

      expect(seen, isEmpty);
      expect(client.authState, AuthState.signedIn,
          reason: 'the session should still have been restored');

      await sub.cancel();
      client.dispose();
    });

    test('emits when a refresh happens with a session established', () async {
      final store = FakeStore(
        creds: _creds(accessExpired: false),
        user: const UserInfo(id: 'u1'),
      );
      final client = build(store);

      await client.waitForInitialization();
      expect(client.authState, AuthState.signedIn);

      final seen = <void>[];
      final sub = client.onTokenRefreshed.listen(seen.add);

      // Age the stored access token, then ask for a token: getAuthToken
      // refreshes inline, which is one of the two paths that must signal.
      store.creds = _creds(accessExpired: true);
      final token = await client.getAuthToken();

      expect(token, 'rotated-access');
      expect(seen, hasLength(1));

      await sub.cancel();
      client.dispose();
    });

    test('does not replay on listen', () async {
      // onAuthChange and onUserChange replay current state; a rotation is an
      // event, so a late listener must not be handed a stale one.
      final store = FakeStore(
        creds: _creds(accessExpired: false),
        user: const UserInfo(id: 'u1'),
      );
      final client = build(store);
      await client.waitForInitialization();

      store.creds = _creds(accessExpired: true);
      await client.getAuthToken();

      final late = <void>[];
      final sub = client.onTokenRefreshed.listen(late.add);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(late, isEmpty);

      await sub.cancel();
      client.dispose();
    });

    test('closes on dispose', () async {
      final client = build(FakeStore());
      var done = false;
      final sub = client.onTokenRefreshed.listen(null, onDone: () => done = true);

      client.dispose();
      await Future.delayed(const Duration(milliseconds: 50));

      expect(done, isTrue);
      await sub.cancel();
    });
  });
}
