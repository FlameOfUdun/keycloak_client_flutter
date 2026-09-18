import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keycloak_client/keycloak_client.dart';

/// An unsigned JWT carrying [claims]. The header is `{}`.
String jwt(Map<String, dynamic> claims) =>
    'e30.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.sig';

void main() {
  group('KeycloakRoles.fromAccessToken', () {
    test('reads realm and client roles', () {
      final roles = KeycloakRoles.fromAccessToken(jwt({
        'realm_access': {'roles': ['staff', 'user']},
        'resource_access': {
          'my-client': {'roles': ['editor']},
          'account': {'roles': ['view-profile']},
        },
      }));

      expect(roles.realm, {'staff', 'user'});
      expect(roles.client, {'my-client': {'editor'}, 'account': {'view-profile'}});
      expect(roles.hasRealmRole('staff'), isTrue);
      expect(roles.hasRealmRole('admin'), isFalse);
      expect(roles.hasClientRole('my-client', 'editor'), isTrue);
      expect(roles.hasClientRole('other', 'editor'), isFalse);
      expect(roles.isEmpty, isFalse);
    });

    test('a token without role claims has no roles', () {
      final roles = KeycloakRoles.fromAccessToken(jwt({'sub': 'u1'}));

      expect(roles.isEmpty, isTrue);
    });

    test('a malformed token has no roles', () {
      for (final token in ['', 'not-a-jwt', 'a.!!!.c', 'a.${base64Url.encode(utf8.encode('[1]'))}.c']) {
        expect(KeycloakRoles.fromAccessToken(token).isEmpty, isTrue, reason: token);
      }
    });

    test('claims of the wrong type are ignored', () {
      final roles = KeycloakRoles.fromAccessToken(jwt({
        'realm_access': {'roles': 'staff'},
        'resource_access': {'my-client': ['editor'], 'ok': {'roles': ['r', 3]}},
      }));

      expect(roles.realm, isEmpty);
      expect(roles.client, {'ok': {'r'}});
    });
  });
}
