import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:keycloak_client/keycloak_client.dart';

class MockStore extends Mock implements IAuthCredentialsStore {}

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
    test(
        'calls refreshOperation exactly once when access token is expired and '
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

      expect(refreshCallCount, 1,
          reason: 'Double-timeout bug: refreshOperation called more than once during initialize()');

      client.dispose();
    });
  });
}
