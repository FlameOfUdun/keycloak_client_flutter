import 'package:flutter_test/flutter_test.dart';
import 'package:keycloak_client/src/enums/refresh_result.dart';
import 'package:keycloak_client/src/models/user_credentials.dart';

void main() {
  group('RefreshResult', () {
    test('RefreshSuccess holds credentials', () {
      final creds = UserCredentials(
        accessToken: 'test-access-token',
        refreshToken: 'test-refresh-token',
        accessTokenExpiry: DateTime.now().add(const Duration(minutes: 5)),
        refreshTokenExpiry: DateTime.now().add(const Duration(days: 30)),
      );
      final result = RefreshSuccess(creds);
      expect(result.credentials, creds);
    });

    test('RefreshTransientFailure holds optional cause', () {
      const withCause = RefreshTransientFailure(cause: 'network down');
      expect(withCause.cause, 'network down');
      const noCause = RefreshTransientFailure();
      expect(noCause.cause, isNull);
    });

    test('RefreshPermanentFailure is a RefreshResult', () {
      const result = RefreshPermanentFailure();
      expect(result, isA<RefreshResult>());
    });

    test('sealed switch covers all subtypes', () {
      RefreshResult r = const RefreshPermanentFailure();
      final label = switch (r) {
        RefreshSuccess() => 'success',
        RefreshTransientFailure() => 'transient',
        RefreshPermanentFailure() => 'permanent',
      };
      expect(label, 'permanent');
    });
  });
}
