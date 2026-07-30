// Drives KeycloakClient against a REAL Keycloak, so the paths that only fail
// against a real server are actually exercised: token refresh over the wire,
// and whether logout truly revokes the session server-side.
//
// Start one with:
//
//   docker run -d --name winche-keycloak-test -p 8080:8080 \
//     -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
//     quay.io/keycloak/keycloak:26.6.1 start-dev
//
// then create realm `winche-test`, public client `flutter-app` with direct
// access grants enabled, and user tester/password123. Skips when nothing is
// listening on 8080.
//
// ignore_for_file: avoid_print — progress output is the point of this file.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:keycloak_client/keycloak_client.dart';

const _baseUrl = 'http://localhost:8080';
const _realm = 'winche-test';
const _clientId = 'flutter-app';
const _username = 'tester';
const _password = 'password123';

Uri get _tokenEndpoint =>
    Uri.parse('$_baseUrl/realms/$_realm/protocol/openid-connect/token');

/// Remembers what was written, standing in for secure storage on the VM.
final class MemoryStore implements IAuthCredentialsStore {
  UserCredentials? creds;
  UserInfo? user;

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

Future<bool> serverIsUp() async {
  try {
    final socket = await Socket.connect(
      'localhost',
      8080,
      timeout: const Duration(seconds: 2),
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Signs in with the password grant — the browser flows cannot be driven from
/// a test, but everything after the code exchange is identical.
Future<Map<String, dynamic>> passwordGrant({List<String> scopes = const []}) async {
  final response = await http.post(
    _tokenEndpoint,
    body: {
      'client_id': _clientId,
      'grant_type': 'password',
      'username': _username,
      'password': _password,
      if (scopes.isNotEmpty) 'scope': scopes.join(' '),
    },
  );
  if (response.statusCode != 200) {
    throw StateError('password grant failed: ${response.statusCode} ${response.body}');
  }
  return jsonDecode(response.body) as Map<String, dynamic>;
}

/// Whether [refreshToken] is still usable at the server.
Future<bool> refreshTokenStillValid(String refreshToken) async {
  final response = await http.post(
    _tokenEndpoint,
    body: {
      'client_id': _clientId,
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
    },
  );
  return response.statusCode == 200;
}

Future<UserInfo> fetchUser(String accessToken) async {
  final response = await http.get(
    Uri.parse('$_baseUrl/realms/$_realm/protocol/openid-connect/userinfo'),
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  return UserInfo.fromApi(jsonDecode(response.body) as Map<String, dynamic>);
}

/// A signed-in client backed by [store], seeded from a real password grant.
Future<KeycloakClient> signedInClient(
  MemoryStore store, {
  List<String> scopes = const ['openid', 'email', 'profile'],
}) async {
  final grant = await passwordGrant(scopes: scopes);
  final isOffline = scopes.contains('offline_access');

  store.creds = UserCredentials(
    accessToken: grant['access_token'] as String,
    refreshToken: grant['refresh_token'] as String,
    accessTokenExpiry: DateTime.now().add(
      Duration(seconds: grant['expires_in'] as int),
    ),
    refreshTokenExpiry: isOffline
        ? DateTime(9999)
        : DateTime.now().add(const Duration(days: 30)),
    idToken: grant['id_token'] as String?,
    isOfflineToken: isOffline,
  );
  // /userinfo needs the openid scope; without it there is no profile to fetch,
  // so seed a placeholder just to get initialize() past its "is there a user"
  // check.
  store.user = scopes.contains('openid')
      ? await fetchUser(grant['access_token'] as String)
      : const UserInfo(id: 'tester');

  final client = KeycloakClient.withDependencies(
    clientConfig: ClientConfig(
      baseUrl: _baseUrl,
      realm: _realm,
      clientId: _clientId,
      scopes: scopes,
    ),
    credentialsStorage: store,
  );
  await client.waitForInitialization();
  return client;
}

/// A [test] that skips itself when no Keycloak is listening, so the default
/// `flutter test` run stays green on a machine without one.
void liveTest(String description, Future<void> Function() body) {
  test(description, () async {
    if (!await serverIsUp()) {
      markTestSkipped('no Keycloak on localhost:8080 — see this file\'s header');
      return;
    }
    await body();
  });
}

void main() {
  liveTest('restores a session from stored credentials', () async {
    final store = MemoryStore();
    final client = await signedInClient(store);

    expect(client.authState, AuthState.signedIn);
    expect(client.currentUser?.username, _username);
    expect(client.currentUser?.email, 'tester@example.com');
    print('  [ok] signed in as ${client.currentUser?.username}');

    client.dispose();
  });

  liveTest('a real refresh rotates the token and announces it', () async {
    final store = MemoryStore();
    final client = await signedInClient(store);
    final before = await client.getAuthToken();

    final rotations = <void>[];
    final sub = client.onTokenRefreshed.listen(rotations.add);

    await client.refreshToken();
    await Future.delayed(const Duration(milliseconds: 300));

    final after = await client.getAuthToken();

    expect(rotations, hasLength(1), reason: 'onTokenRefreshed did not fire');
    expect(after, isNotNull);
    expect(after, isNot(before), reason: 'the access token did not change');
    expect(store.creds!.accessToken, after);
    print('  [ok] rotated, and the new token is what getAuthToken returns');

    await sub.cancel();
    client.dispose();
  });

  liveTest('logout revokes the refresh token at the server', () async {
    // The regression this guards: `id_token_hint` was sent as a literal null,
    // http threw casting the body to form fields, and revokeSession swallowed
    // it. The local session cleared either way, so the only way to see the
    // difference is to ask Keycloak whether the token still works.
    final store = MemoryStore();
    final client = await signedInClient(store);
    final refreshToken = store.creds!.refreshToken;

    expect(await refreshTokenStillValid(refreshToken), isTrue,
        reason: 'precondition: the token should work before logout');

    await client.logout();

    expect(client.authState, AuthState.signedOut);
    expect(store.creds, isNull, reason: 'local credentials were not cleared');
    expect(await refreshTokenStillValid(refreshToken), isFalse,
        reason: 'the session is still alive at Keycloak after logout');
    print('  [ok] logout revoked the session server-side');

    client.dispose();
  });

  liveTest('logout revokes even when the session has no ID token', () async {
    // This is the case the bug actually broke. Keycloak only issues an
    // id_token for an `openid` session, so with any other scope set
    // `id_token_hint` is null — and it was being sent as a literal null rather
    // than omitted, which made the body a Map<String, String?>, threw inside
    // http, and was swallowed whole by revokeSession's bare catch.
    //
    // The openid case above cannot see this: it always has an ID token.
    final store = MemoryStore();
    final client = await signedInClient(
      store,
      scopes: const ['email', 'profile'],
    );

    expect(store.creds!.idToken, isNull, reason: 'precondition: no ID token');
    final refreshToken = store.creds!.refreshToken;
    expect(await refreshTokenStillValid(refreshToken), isTrue);

    await client.logout();

    expect(await refreshTokenStillValid(refreshToken), isFalse,
        reason: 'the session is still alive at Keycloak after logout');
    print('  [ok] logout revoked a session that had no ID token');

    client.dispose();
  });

  liveTest('an offline_access session is stored without a local expiry', () async {
    final store = MemoryStore();
    final client = await signedInClient(
      store,
      scopes: const ['openid', 'email', 'profile', 'offline_access'],
    );

    // Force a refresh: this is where an offline session used to be silently
    // downgraded to a dated one.
    await client.refreshToken();
    await Future.delayed(const Duration(milliseconds: 300));

    expect(store.creds!.isOfflineToken, isTrue);
    expect(store.creds!.isRefreshExpired, isFalse);
    expect(store.creds!.refreshTokenExpiry.year, 9999);
    print('  [ok] offline session survived a refresh intact');

    client.dispose();
  });

  liveTest('a revoked session ends with KeycloakSessionExpiredException', () async {
    final store = MemoryStore();
    final client = await signedInClient(store);

    // Kill the session out from under the client, the way an admin logging the
    // user out everywhere would.
    await http.post(
      Uri.parse('$_baseUrl/realms/$_realm/protocol/openid-connect/logout'),
      body: {
        'client_id': _clientId,
        'refresh_token': store.creds!.refreshToken,
      },
    );

    await expectLater(
      client.refreshToken(),
      throwsA(isA<KeycloakSessionExpiredException>()),
    );
    expect(client.authState, AuthState.sessionExpired);
    print('  [ok] a dead session surfaces as sessionExpired, not silence');

    client.dispose();
  });
}
