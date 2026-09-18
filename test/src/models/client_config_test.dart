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

  group('ClientConfig.missingRoles', () {
    const config = ClientConfig(
      baseUrl: 'http://localhost',
      realm: 'r',
      clientId: 'c',
      requiredRealmRoles: {'staff'},
      requiredClientRoles: {'my-client': {'editor', 'viewer'}},
    );

    test('nothing is missing when every required role is held', () {
      const granted = KeycloakRoles(
        realm: {'staff', 'extra'},
        client: {'my-client': {'editor', 'viewer'}},
      );

      expect(config.missingRoles(granted).isEmpty, isTrue);
    });

    test('reports only what is missing', () {
      const granted = KeycloakRoles(client: {'my-client': {'viewer'}});

      final missing = config.missingRoles(granted);

      expect(missing.realm, {'staff'});
      expect(missing.client, {'my-client': {'editor'}});
    });

    test('a client the principal has no roles in counts as missing', () {
      final missing = config.missingRoles(const KeycloakRoles(realm: {'staff'}));

      expect(missing.client, {'my-client': {'editor', 'viewer'}});
    });

    test('no requirements means nothing is ever missing', () {
      const plain = ClientConfig(baseUrl: 'http://localhost', realm: 'r', clientId: 'c');

      expect(plain.missingRoles(const KeycloakRoles()).isEmpty, isTrue);
    });
  });
}
