import 'package:flutter_test/flutter_test.dart';
import 'package:keycloak_client/keycloak_client.dart';

void main() {
  group('ClientConfig.grantType', () {
    test('defaults to authorizationCode, so existing configs are unchanged', () {
      const config = ClientConfig(baseUrl: 'http://localhost', realm: 'r', clientId: 'c');

      expect(config.grantType, GrantType.authorizationCode);
      expect(config.isServiceAccount, isFalse);
    });

    test('clientCredentials marks the config as a service account', () {
      const config = ClientConfig(
        baseUrl: 'http://localhost',
        realm: 'r',
        clientId: 'c',
        clientSecret: 's',
        grantType: GrantType.clientCredentials,
      );

      expect(config.isServiceAccount, isTrue);
    });

    test('a secret alone does not switch the mode', () {
      // Confidential clients pass a secret for browser login and must keep it.
      const config = ClientConfig(baseUrl: 'http://localhost', realm: 'r', clientId: 'c', clientSecret: 's');

      expect(config.isServiceAccount, isFalse);
    });
  });
}
