import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:logger/logger.dart';
import 'package:keycloak_client/src/core/token_service.dart';
import 'package:keycloak_client/src/enums/refresh_result.dart';
import 'package:keycloak_client/src/interfaces/auth_credentials_store.dart';
import 'package:keycloak_client/src/models/user_credentials.dart';

class MockStore extends Mock implements IAuthCredentialsStore {}

class MockOAuth2Client extends Mock implements oauth2.Client {}

UserCredentials _validCreds() => UserCredentials(
  accessToken: 'test-access-token',
  refreshToken: 'test-refresh-token',
  accessTokenExpiry: DateTime.now().add(const Duration(minutes: 5)),
  refreshTokenExpiry: DateTime.now().add(const Duration(days: 30)),
);

UserCredentials _expiredRefreshCreds() => UserCredentials(
  accessToken: 'test-access-token',
  refreshToken: 'test-refresh-token',
  accessTokenExpiry: DateTime.now().subtract(const Duration(hours: 1)),
  refreshTokenExpiry: DateTime.now().subtract(const Duration(hours: 1)),
);

oauth2.Credentials _oauth2Creds(UserCredentials uc) => oauth2.Credentials(
  uc.accessToken,
  refreshToken: uc.refreshToken,
  expiration: uc.accessTokenExpiry,
  tokenEndpoint: Uri.parse(
    'http://localhost/realms/test/protocol/openid-connect/token',
  ),
);

void main() {
  late MockStore store;
  late MockOAuth2Client oauthClient;
  var permanentCalls = 0;
  var recoveryCalls = 0;
  final logger = Logger(level: Level.off);

  setUpAll(() {
    registerFallbackValue(_validCreds());
  });

  setUp(() {
    store = MockStore();
    oauthClient = MockOAuth2Client();
    permanentCalls = 0;
    recoveryCalls = 0;
  });

  TokenService _makeService(
    Future<oauth2.Client> Function(oauth2.Client, List<String>) refreshOp, {
    Duration refreshTimeout = const Duration(seconds: 15),
  }) {
    return TokenService(
      store: store,
      scopes: const ['openid'],
      onPermanentFailure: () async => permanentCalls++,
      onRecovery: () => recoveryCalls++,
      logger: logger,
      refreshOperation: refreshOp,
      refreshTimeout: refreshTimeout,
    );
  }

  group('successful refresh', () {
    test('stores new credentials and returns RefreshSuccess', () async {
      final newCreds = _validCreds();
      when(() => oauthClient.credentials).thenReturn(_oauth2Creds(newCreds));
      when(() => store.setCredentials(any())).thenAnswer((_) async {});

      final service = _makeService((_, __) async => oauthClient);
      service.setClient(oauthClient);

      final result = await service.attemptRefresh();

      expect(result, isA<RefreshSuccess>());
      verify(() => store.setCredentials(any())).called(1);
      service.dispose();
    });

    test('does not call onPermanentFailure on success', () async {
      final newCreds = _validCreds();
      when(() => oauthClient.credentials).thenReturn(_oauth2Creds(newCreds));
      when(() => store.setCredentials(any())).thenAnswer((_) async {});

      final service = _makeService((_, __) async => oauthClient);
      service.setClient(oauthClient);

      await service.attemptRefresh();

      expect(permanentCalls, 0);
      service.dispose();
    });
  });

  group('transient failure — SocketException', () {
    test(
      'returns RefreshTransientFailure when refresh token is still valid',
      () async {
        when(
          () => store.getCredentials(),
        ).thenAnswer((_) async => _validCreds());

        final service = _makeService(
          (_, __) async => throw const SocketException('offline'),
        );
        service.setClient(oauthClient);

        final result = await service.attemptRefresh();

        expect(result, isA<RefreshTransientFailure>());
        expect(permanentCalls, 0);
      },
    );

    test(
      'returns RefreshPermanentFailure when refresh token is locally expired',
      () async {
        when(
          () => store.getCredentials(),
        ).thenAnswer((_) async => _expiredRefreshCreds());

        final service = _makeService(
          (_, __) async => throw const SocketException('offline'),
        );
        service.setClient(oauthClient);

        final result = await service.attemptRefresh();

        expect(result, isA<RefreshPermanentFailure>());
        expect(permanentCalls, 1);
      },
    );
  });

  group('transient failure — non-invalid_grant AuthorizationException', () {
    test(
      'returns RefreshTransientFailure when refresh token is still valid',
      () async {
        when(
          () => store.getCredentials(),
        ).thenAnswer((_) async => _validCreds());

        final service = _makeService(
          (_, __) async =>
              throw oauth2.AuthorizationException('server_error', null, null),
        );
        service.setClient(oauthClient);

        final result = await service.attemptRefresh();

        expect(result, isA<RefreshTransientFailure>());
        expect(permanentCalls, 0);
      },
    );

    test(
      'returns RefreshPermanentFailure when refresh token is locally expired',
      () async {
        when(
          () => store.getCredentials(),
        ).thenAnswer((_) async => _expiredRefreshCreds());

        final service = _makeService(
          (_, __) async =>
              throw oauth2.AuthorizationException('server_error', null, null),
        );
        service.setClient(oauthClient);

        final result = await service.attemptRefresh();

        expect(result, isA<RefreshPermanentFailure>());
        expect(permanentCalls, 1);
      },
    );
  });

  group('permanent failure', () {
    test(
      'invalid_grant calls onPermanentFailure and returns RefreshPermanentFailure',
      () async {
        final service = _makeService(
          (_, __) async =>
              throw oauth2.AuthorizationException('invalid_grant', null, null),
        );
        service.setClient(oauthClient);

        final result = await service.attemptRefresh();

        expect(result, isA<RefreshPermanentFailure>());
        expect(permanentCalls, 1);
      },
    );

    test(
      'ExpirationException calls onPermanentFailure and returns RefreshPermanentFailure',
      () async {
        final expiredOauthCreds = _oauth2Creds(_validCreds());
        final service = _makeService(
          (_, __) async => throw oauth2.ExpirationException(expiredOauthCreds),
        );
        service.setClient(oauthClient);

        final result = await service.attemptRefresh();

        expect(result, isA<RefreshPermanentFailure>());
        expect(permanentCalls, 1);
      },
    );

    test(
      'null client calls onPermanentFailure and returns RefreshPermanentFailure',
      () async {
        final service = _makeService((_, __) async => oauthClient);
        // Do NOT call service.setClient — _oauthClient remains null

        final result = await service.attemptRefresh();

        expect(result, isA<RefreshPermanentFailure>());
        expect(permanentCalls, 1);
      },
    );
  });

  group('coalescing', () {
    test(
      'concurrent attemptRefresh calls share the same in-flight future',
      () async {
        var callCount = 0;
        when(
          () => store.getCredentials(),
        ).thenAnswer((_) async => _validCreds());

        final service = _makeService((_, __) async {
          callCount++;
          throw const SocketException('offline');
        });
        service.setClient(oauthClient);

        await Future.wait([
          service.attemptRefresh(),
          service.attemptRefresh(),
          service.attemptRefresh(),
        ]);

        expect(callCount, 1);
      },
    );
  });

  group('recovery detection', () {
    test(
      'calls onRecovery when transitioning from failure to success',
      () async {
        when(
          () => store.getCredentials(),
        ).thenAnswer((_) async => _validCreds());

        // First refresh: transient failure
        var shouldFail = true;
        final newCreds = _validCreds();
        when(() => oauthClient.credentials).thenReturn(_oauth2Creds(newCreds));
        when(() => store.setCredentials(any())).thenAnswer((_) async {});

        final service = _makeService((_, __) async {
          if (shouldFail) throw const SocketException('offline');
          return oauthClient;
        });
        service.setClient(oauthClient);

        // First call fails — sets _previousRefreshFailed = true
        await service.attemptRefresh();
        expect(recoveryCalls, 0);

        // Allow new completer (prior one is completed)
        shouldFail = false;

        // Second call succeeds — should call onRecovery
        await service.attemptRefresh();
        expect(recoveryCalls, 1);
        service.dispose();
      },
    );

    test('does not call onRecovery when first refresh succeeds', () async {
      final newCreds = _validCreds();
      when(() => oauthClient.credentials).thenReturn(_oauth2Creds(newCreds));
      when(() => store.setCredentials(any())).thenAnswer((_) async {});

      final service = _makeService((_, __) async => oauthClient);
      service.setClient(oauthClient);

      await service.attemptRefresh();

      expect(recoveryCalls, 0);
      service.dispose();
    });
  });

  group('timeout', () {
    test('hanging refresh returns RefreshTransientFailure', () async {
      when(() => store.getCredentials()).thenAnswer((_) async => _validCreds());

      final service = _makeService(
        (_, __) => Completer<oauth2.Client>().future, // never resolves
        refreshTimeout: const Duration(milliseconds: 100),
      );
      service.setClient(oauthClient);

      final result = await service.attemptRefresh();

      expect(result, isA<RefreshTransientFailure>());
      expect(permanentCalls, 0);
      service.dispose();
    });

    test(
      'hanging refresh with locally expired refresh token ends session',
      () async {
        when(
          () => store.getCredentials(),
        ).thenAnswer((_) async => _expiredRefreshCreds());

        final service = _makeService(
          (_, __) => Completer<oauth2.Client>().future,
          refreshTimeout: const Duration(milliseconds: 100),
        );
        service.setClient(oauthClient);

        final result = await service.attemptRefresh();

        expect(result, isA<RefreshPermanentFailure>());
        expect(permanentCalls, 1);
        service.dispose();
      },
    );
  });
}
