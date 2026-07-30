@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:keycloak_client/keycloak_client.dart';
import 'package:keycloak_client/src/strategies/web_login_strategy.dart';

/// In-memory [IPendingGrantStore] so these tests never touch sessionStorage.
final class FakeGrantStore implements IPendingGrantStore {
  final grants = <String, PendingGrant>{};
  var sweeps = 0;

  @override
  void put(PendingGrant grant) => grants[grant.state] = grant;

  @override
  PendingGrant? takeValid(String state) {
    final grant = grants.remove(state);
    if (grant == null || grant.isExpired) return null;
    return grant;
  }

  @override
  bool isExpired(String state) => grants[state]?.isExpired ?? false;

  @override
  void sweepExpired() {
    sweeps++;
    grants.removeWhere((_, g) => g.isExpired);
  }
}

ClientConfig config({String? clientSecret}) => ClientConfig(
  baseUrl: 'http://localhost:8080',
  realm: 'test',
  clientId: 'app',
  clientSecret: clientSecret,
);

void main() {
  late FakeGrantStore store;
  late List<Uri> redirects;
  late WebLoginStrategy strategy;

  setUp(() {
    store = FakeGrantStore();
    redirects = [];
    strategy = WebLoginStrategy.withDependencies(
      store: store,
      redirect: redirects.add,
    );
  });

  /// Starts a login without awaiting: on web the future never completes
  /// because the tab is expected to be unloading.
  Future<void> startLogin({
    WebConfig platformConfig = const WebConfig(),
    ClientConfig? clientConfig,
  }) async {
    strategy
        .login(
          platformConfig: platformConfig,
          clientConfig: clientConfig ?? config(),
        )
        .ignore();
    await Future<void>.delayed(Duration.zero);
  }

  group('login()', () {
    test('uses the injected redirect instead of navigating the tab', () async {
      // The constructor took this callback and dropped it, so a test written
      // against its own documentation navigated the real browser tab.
      await startLogin();

      expect(redirects, hasLength(1));
      expect(redirects.single.path, contains('/protocol/openid-connect/auth'));
    });

    test('sends a state parameter', () async {
      await startLogin();

      final state = redirects.single.queryParameters['state'];
      expect(state, isNotNull);
      expect(state, hasLength(32));
      expect(store.grants.keys, [state]);
    });

    test('persists the TTL configured on WebConfig', () async {
      // The store used to hold its own 10-minute default and this value was
      // never read, so the documented setting did nothing.
      await startLogin(
        platformConfig: const WebConfig(pendingGrantTTL: Duration(minutes: 3)),
      );

      expect(store.grants.values.single.ttlMs, const Duration(minutes: 3).inMilliseconds);
    });

    test('never writes the client secret into the stored grant', () async {
      await startLogin(clientConfig: config(clientSecret: 'super-secret'));

      final json = store.grants.values.single.toJsonString();
      expect(json, isNot(contains('super-secret')));
    });
  });

  group('handleCallback()', () {
    Future<void> seed() => startLogin();

    String state() => store.grants.keys.single;

    test('returns null when the user declined at the consent screen', () async {
      await seed();

      final result = await strategy.handleCallback(
        Uri.parse('http://app/?state=${state()}&error=access_denied'),
      );

      expect(result, isNull);
    });

    test('throws for any other IdP error', () async {
      // These used to be reported as a cancellation, leaving a misconfigured
      // client indistinguishable from a user changing their mind.
      await seed();
      final uri = Uri.parse('http://app/?state=${state()}&error=invalid_scope');

      await expectLater(
        strategy.handleCallback(uri),
        throwsA(isA<KeycloakServerException>()),
      );
    });

    test('consumes the grant even when the IdP reported an error', () async {
      await seed();
      final captured = state();

      await strategy
          .handleCallback(
            Uri.parse('http://app/?state=$captured&error=access_denied'),
          )
          .catchError((_) => null);

      expect(store.grants, isEmpty, reason: 'a used grant must not be replayable');
    });

    test('returns null for an unknown state', () async {
      await seed();

      final result = await strategy.handleCallback(
        Uri.parse('http://app/?state=not-a-real-state&code=abc'),
      );

      expect(result, isNull);
    });

    test('throws KeycloakTimeoutException once the grant has aged out',
        () async {
      await startLogin(
        platformConfig: const WebConfig(pendingGrantTTL: Duration.zero),
      );

      await expectLater(
        strategy.handleCallback(
          Uri.parse('http://app/?state=${state()}&code=abc'),
        ),
        throwsA(isA<KeycloakTimeoutException>()),
      );
    });
  });
}
