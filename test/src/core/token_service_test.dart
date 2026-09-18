import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oauth2/oauth2.dart' as oauth2;
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
  var refreshedCalls = 0;
  final logger = Logger('TokenServiceTest');

  setUpAll(() {
    registerFallbackValue(_validCreds());
    registerFallbackValue(Uri.parse('http://localhost'));
  });

  setUp(() {
    store = MockStore();
    oauthClient = MockOAuth2Client();
    permanentCalls = 0;
    recoveryCalls = 0;
    refreshedCalls = 0;
  });

  TokenService _makeService(
    Future<oauth2.Client> Function(oauth2.Client, List<String>) refreshOp, {
    Duration refreshTimeout = const Duration(seconds: 15),
    Duration refreshTokenLifetime = const Duration(days: 30),
    bool isOfflineSession = false,
    Set<String>? permanentAuthErrors,
  }) {
    return TokenService(
      store: store,
      scopes: const ['openid'],
      refreshTokenLifetime: refreshTokenLifetime,
      isOfflineSession: isOfflineSession,
      onPermanentFailure: () async => permanentCalls++,
      onRecovery: () => recoveryCalls++,
      onTokenRefreshed: () => refreshedCalls++,
      logger: logger,
      refreshOperation: refreshOp,
      refreshTimeout: refreshTimeout,
      permanentAuthErrors: permanentAuthErrors,
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

  group('refresh preserves session shape', () {
    /// Runs one successful refresh and returns what was written to the store.
    Future<UserCredentials> refreshAndCapture({
      required bool isOfflineSession,
      Duration refreshTokenLifetime = const Duration(days: 30),
    }) async {
      late UserCredentials written;
      when(() => oauthClient.credentials).thenReturn(_oauth2Creds(_validCreds()));
      when(() => store.setCredentials(any())).thenAnswer((invocation) async {
        written = invocation.positionalArguments.first as UserCredentials;
      });

      final service = _makeService(
        (_, __) async => oauthClient,
        isOfflineSession: isOfflineSession,
        refreshTokenLifetime: refreshTokenLifetime,
      );
      service.setClient(oauthClient);
      await service.attemptRefresh();
      service.dispose();
      return written;
    }

    test('an offline session stays offline across a refresh', () async {
      // oauth2.Credentials carries neither `refresh_expires_in` nor any offline
      // marker, so a refresh that does not re-supply them downgrades an offline
      // session to a dated one. The user is then signed out by initialize()
      // once that invented expiry passes — against a refresh token Keycloak
      // would still have accepted.
      final written = await refreshAndCapture(isOfflineSession: true);

      expect(written.isOfflineToken, isTrue);
      expect(written.isRefreshExpired, isFalse);
      expect(written.refreshTokenExpiry.year, 9999);
    });

    test('a normal session keeps a real expiry', () async {
      final written = await refreshAndCapture(isOfflineSession: false);

      expect(written.isOfflineToken, isFalse);
      expect(written.refreshTokenExpiry.year, isNot(9999));
    });

    test('refreshTokenLifetime sets how far the expiry is pushed', () async {
      final written = await refreshAndCapture(
        isOfflineSession: false,
        refreshTokenLifetime: const Duration(minutes: 30),
      );

      final remaining = written.refreshTokenExpiry.difference(DateTime.now());
      expect(remaining, lessThanOrEqualTo(const Duration(minutes: 30)));
      expect(remaining, greaterThan(const Duration(minutes: 29)));
    });
  });

  group('onTokenRefreshed', () {
    test('fires once on a successful refresh', () async {
      when(() => oauthClient.credentials).thenReturn(_oauth2Creds(_validCreds()));
      when(() => store.setCredentials(any())).thenAnswer((_) async {});

      final service = _makeService((_, __) async => oauthClient);
      service.setClient(oauthClient);

      await service.attemptRefresh();

      expect(refreshedCalls, 1);
      service.dispose();
    });

    test('stays silent on a transient failure', () async {
      // The token did not change, so a consumer holding one has no reason to
      // re-dial — and the retry is already scheduled.
      when(() => store.getCredentials()).thenAnswer((_) async => _validCreds());

      final service = _makeService(
        (_, __) async => throw const SocketException('offline'),
      );
      service.setClient(oauthClient);

      final result = await service.attemptRefresh();

      expect(result, isA<RefreshTransientFailure>());
      expect(refreshedCalls, 0);
      service.dispose();
    });

    test('stays silent on a permanent failure', () async {
      final service = _makeService(
        (_, __) async =>
            throw oauth2.AuthorizationException('invalid_grant', null, null),
      );
      service.setClient(oauthClient);

      final result = await service.attemptRefresh();

      expect(result, isA<RefreshPermanentFailure>());
      expect(refreshedCalls, 0);
      service.dispose();
    });
  });

  group('revokeSession', () {
    /// Captures the body of the single POST [revokeSession] makes.
    Future<Map<String, dynamic>?> capturePostBody(String? idToken) async {
      Map<String, dynamic>? body;
      when(() => oauthClient.post(any(), body: any(named: 'body'))).thenAnswer((
        invocation,
      ) async {
        body = invocation.namedArguments[#body] as Map<String, dynamic>;
        return http.Response('', 204);
      });

      final service = _makeService((_, __) async => oauthClient);
      service.setClient(oauthClient);
      await service.revokeSession(
        logoutEndpoint: Uri.parse('http://localhost/logout'),
        clientId: 'test-client',
        refreshToken: 'test-refresh-token',
        idToken: idToken,
      );
      service.dispose();
      return body;
    }

    test('omits id_token_hint entirely when there is no ID token', () async {
      // Carrying the key with a null value makes the body a
      // Map<String, String?>, which http rejects when it casts to form fields.
      // revokeSession swallows every throw, so the request never reaches
      // Keycloak and the refresh token stays valid server-side while the local
      // session clears — a logout that looks successful and isn't.
      final body = await capturePostBody(null);

      expect(body, isNotNull, reason: 'no logout request was sent');
      expect(body!.containsKey('id_token_hint'), isFalse);
      expect(body, containsPair('client_id', 'test-client'));
      expect(body, containsPair('refresh_token', 'test-refresh-token'));
    });

    test('sends id_token_hint when an ID token is present', () async {
      final body = await capturePostBody('test-id-token');

      expect(body, containsPair('id_token_hint', 'test-id-token'));
    });
  });

  group('refresh finishing after invalidate()', () {
    test('is dropped without storing or ending the session again', () async {
      final release = Completer<void>();
      final next = MockOAuth2Client();
      when(() => next.credentials).thenReturn(_oauth2Creds(_validCreds()));
      when(() => store.setCredentials(any())).thenAnswer((_) async {});

      final service = _makeService((_, _) async {
        await release.future;
        return next;
      });
      service.setClient(oauthClient);

      final pending = service.attemptRefresh();
      service.invalidate();
      release.complete();
      final result = await pending;

      expect(result, isA<RefreshPermanentFailure>());
      verifyNever(() => store.setCredentials(any()));
      expect(permanentCalls, 0);
      verify(() => next.close()).called(1);
      service.dispose();
    });
  });

  group('refresh failing after invalidate()', () {
    test('a transport error is dropped without ending the session again', () async {
      late final TokenService service;
      service = _makeService((_, _) async {
        service.invalidate();
        throw http.ClientException('closed');
      });
      service.setClient(oauthClient);

      final result = await service.attemptRefresh();

      expect(result, isA<RefreshPermanentFailure>());
      expect(permanentCalls, 0);
      verifyNever(() => store.getCredentials());
      verifyNever(() => store.setCredentials(any()));
      service.dispose();
    });

    test('a permanent auth error is dropped without ending the session again', () async {
      late final TokenService service;
      service = _makeService((_, _) async {
        service.invalidate();
        throw oauth2.AuthorizationException('invalid_grant', null, null);
      });
      service.setClient(oauthClient);

      final result = await service.attemptRefresh();

      expect(result, isA<RefreshPermanentFailure>());
      expect(permanentCalls, 0);
      service.dispose();
    });
  });

  group('transient failure — FormatException', () {
    test('returns RefreshTransientFailure and schedules a retry', () async {
      when(() => store.getCredentials()).thenAnswer((_) async => _validCreds());
      final service = _makeService(
        (_, _) async => throw const FormatException('bad 502 body'),
      );
      service.setClient(oauthClient);

      final result = await service.attemptRefresh();

      expect(result, isA<RefreshTransientFailure>());
      expect(permanentCalls, 0);
      // The retry path reads the store to decide whether to reschedule.
      verify(() => store.getCredentials()).called(1);
      service.dispose();
    });
  });

  group('revokeSession timeout', () {
    test('a logout POST that never answers gives up after refreshTimeout', () async {
      when(() => oauthClient.post(any(), body: any(named: 'body')))
          .thenAnswer((_) => Completer<http.Response>().future);

      final service = _makeService(
        (_, _) async => oauthClient,
        refreshTimeout: const Duration(milliseconds: 100),
      );
      service.setClient(oauthClient);

      final watch = Stopwatch()..start();
      await service
          .revokeSession(
            logoutEndpoint: Uri.parse('http://localhost/logout'),
            clientId: 'test-client',
            refreshToken: 'test-refresh-token',
          )
          .timeout(const Duration(seconds: 2), onTimeout: () => fail('revokeSession hung'));

      expect(watch.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 90)));
      service.dispose();
    });
  });

  group('refresh finishing after its timeout', () {
    test('closes the client it produced', () async {
      when(() => store.getCredentials()).thenAnswer((_) async => _validCreds());
      final release = Completer<void>();
      final late = MockOAuth2Client();

      final service = _makeService((_, _) async {
        await release.future;
        return late;
      }, refreshTimeout: const Duration(milliseconds: 50));
      service.setClient(oauthClient);

      final result = await service.attemptRefresh();
      expect(result, isA<RefreshTransientFailure>());

      release.complete();
      await Future.delayed(const Duration(milliseconds: 20));

      verify(() => late.close()).called(1);
      verifyNever(() => oauthClient.close());
      service.dispose();
    });

    test('never closes the current client when the refresh returns it', () async {
      // The auth-code refresh (refreshCredentials) returns the same instance.
      when(() => store.getCredentials()).thenAnswer((_) async => _validCreds());
      final release = Completer<void>();

      final service = _makeService((current, _) async {
        await release.future;
        return current;
      }, refreshTimeout: const Duration(milliseconds: 50));
      service.setClient(oauthClient);

      await service.attemptRefresh();
      release.complete();
      await Future.delayed(const Duration(milliseconds: 20));

      verifyNever(() => oauthClient.close());
      service.dispose();
    });
  });

  group('setClient', () {
    test('closes the client it replaces', () async {
      final next = MockOAuth2Client();
      final service = _makeService((_, _) async => oauthClient);

      service.setClient(oauthClient);
      service.setClient(next);
      service.setClient(next);

      verify(() => oauthClient.close()).called(1);
      verifyNever(() => next.close());
      service.dispose();
    });

    test('does not close anything after invalidate()', () async {
      final next = MockOAuth2Client();
      final service = _makeService((_, _) async => oauthClient);

      service.setClient(oauthClient);
      service.invalidate();
      verify(() => oauthClient.close()).called(1);
      service.setClient(next);

      verifyNever(() => oauthClient.close());
      verifyNever(() => next.close());
      service.dispose();
    });

    test('a refresh in flight when the client is replaced is discarded', () async {
      final release = Completer<void>();
      final refreshed = MockOAuth2Client();
      final replacement = MockOAuth2Client();
      when(() => store.setCredentials(any())).thenAnswer((_) async {});

      final service = _makeService((_, _) async {
        await release.future;
        return refreshed;
      });
      service.setClient(oauthClient);

      final pending = service.attemptRefresh();
      service.setClient(replacement);
      release.complete();
      final result = await pending;

      expect(result, isA<RefreshPermanentFailure>());
      expect(service.oauthClient, same(replacement));
      verify(() => oauthClient.close()).called(1);
      verify(() => refreshed.close()).called(1);
      verifyNever(() => replacement.close());
      verifyNever(() => store.setCredentials(any()));
      expect(permanentCalls, 0);
      service.dispose();
    });
  });

  group('permanentAuthErrors', () {
    test('by default invalid_client is transient', () async {
      when(() => store.getCredentials()).thenAnswer((_) async => _validCreds());
      final service = _makeService(
        (_, __) async => throw oauth2.AuthorizationException('invalid_client', null, null),
      );
      service.setClient(oauthClient);

      final result = await service.attemptRefresh();

      expect(result, isA<RefreshTransientFailure>());
      expect(permanentCalls, 0);
      service.dispose();
    });

    test('a listed error ends the session without retrying', () async {
      final service = _makeService(
        (_, __) async => throw oauth2.AuthorizationException('invalid_client', null, null),
        permanentAuthErrors: const {'invalid_grant', 'invalid_client'},
      );
      service.setClient(oauthClient);

      final result = await service.attemptRefresh();

      expect(result, isA<RefreshPermanentFailure>());
      expect(permanentCalls, 1);
      service.dispose();
    });
  });
}
