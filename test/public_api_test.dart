import 'package:flutter_test/flutter_test.dart';
import 'package:keycloak_client/keycloak_client.dart';

void main() {
  test('the default credentials store is exported', () {
    // A consumer overriding the login strategy must not have to re-implement
    // storage (and its key names) just to fill the credentialsStorage slot.
    const IAuthCredentialsStore store = SecureStorageAuthCredentialsStore();
    expect(store, isA<SecureStorageAuthCredentialsStore>());
  });

  test('the PKCE helpers are exported', () {
    final verifier = generateCodeVerifier();

    expect(verifier, hasLength(64));
    expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(verifier), isTrue);
    expect(generateCodeVerifier(), isNot(verifier));
    expect(generateState(), matches(RegExp(r'^[0-9a-f]{32}$')));
  });
}
