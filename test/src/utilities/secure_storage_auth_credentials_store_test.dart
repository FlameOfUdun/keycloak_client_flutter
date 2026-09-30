import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keycloak_client/keycloak_client.dart';

/// A fake of flutter_secure_storage's platform side: one key space per keychain mode, and a switch for each mode to
/// refuse writes the way macOS refuses an app without the keychain entitlement (-34018).
class _FakeKeychain {
  final modern = <String, String>{};

  /// The login keychain, by service name (flutter_secure_storage's accountName).
  final logins = <String, Map<String, String>>{};
  bool refuseModern = false;
  bool refuseLogin = false;

  /// Items another build of the app made: there, but the keychain won't hand them to this one (-60008).
  final foreign = <String>{};

  Map<String, String> get login => logins.values.fold({}, (all, m) => {...all, ...m});

  Future<Object?> handle(MethodCall call) async {
    final args = (call.arguments as Map).cast<String, Object?>();
    final options = (args['options'] as Map?)?.cast<String, String>() ?? const {};
    final usesModern = options['usesDataProtectionKeychain'] != 'false';
    final space = usesModern ? modern : logins.putIfAbsent(options['accountName'] ?? 'default', () => {});
    final key = args['key'] as String?;
    switch (call.method) {
      case 'write':
        if (usesModern ? refuseModern : refuseLogin) {
          throw PlatformException(code: '-34018', message: 'A required entitlement isn\'t present.');
        }
        space[key!] = args['value'] as String;
        return null;
      case 'read':
        if (foreign.contains(key)) throw PlatformException(code: '-60008', message: 'Unable to obtain authorization for this operation.');
        return space[key];
      case 'delete':
        foreign.remove(key);
        space.remove(key);
        return null;
      default:
        return null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late _FakeKeychain keychain;

  final user = UserInfo.fromJson(const {'id': 'u1', 'username': 'sam'});

  setUp(() {
    keychain = _FakeKeychain();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, keychain.handle);
    SecureStorageAuthCredentialsStore.resetForTesting();
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('an entitled Mac app keeps the data-protection keychain', () async {
    const store = SecureStorageAuthCredentialsStore();
    await store.setUser(user);

    expect(keychain.modern, contains('keycloak_client_user'));
    expect(keychain.login, isEmpty);
    expect((await store.getUser())?.toJson(), user.toJson());
  });

  test('a Mac app the data-protection keychain refuses uses the login keychain', () async {
    keychain.refuseModern = true;
    const store = SecureStorageAuthCredentialsStore();
    await store.setUser(user);

    expect(keychain.login, contains('keycloak_client_user'));
    expect(keychain.modern, isEmpty);
    expect((await store.getUser())?.toJson(), user.toJson());
    expect(keychain.login, isNot(contains('keycloak_client_probe'))); // the check leaves nothing behind
  });

  test('when no keychain accepts the app, the first read fails with a KeycloakStorageException', () async {
    keychain
      ..refuseModern = true
      ..refuseLogin = true;
    const store = SecureStorageAuthCredentialsStore();

    await expectLater(store.getCredentials(), throwsA(isA<KeycloakStorageException>()));

    // Not remembered as a failure: once a keychain works, the next use succeeds.
    keychain.refuseLogin = false;
    expect(await store.getCredentials(), isNull);
  });

  test('other platforms never fall back: an unusable store fails clearly', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    keychain.refuseModern = true; // the only mode off macOS
    const store = SecureStorageAuthCredentialsStore();

    await expectLater(store.getUser(), throwsA(isA<KeycloakStorageException>()));
    expect(keychain.login, isEmpty);
  });

  test('an explicit storage is used as given, without a check', () async {
    keychain.refuseModern = true;
    const store = SecureStorageAuthCredentialsStore(
      storage: FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false)),
    );
    await store.setUser(user);

    expect(keychain.login.keys, ['keycloak_client_user']);
  });

  test('in the login keychain each app has its own name, so their saved logins never meet', () async {
    keychain.refuseModern = true;
    const crm = SecureStorageAuthCredentialsStore(namespace: 'keycloak_client:crm-app@crm/localhost:8080');
    const other = SecureStorageAuthCredentialsStore(namespace: 'keycloak_client:other@winche/auth.example.com');
    await crm.setUser(user);

    expect(keychain.logins['keycloak_client:crm-app@crm/localhost:8080'], contains('keycloak_client_user'));
    expect(await other.getUser(), isNull);
    expect((await crm.getUser())?.toJson(), user.toJson());
  });

  test('a saved login the keychain won\'t show this build is treated as signed out, and replaced on the next save',
      () async {
    keychain.refuseModern = true;
    const store = SecureStorageAuthCredentialsStore(namespace: 'app');
    await store.setUser(user);
    keychain.foreign.add('keycloak_client_user');

    expect(await store.getUser(), isNull);

    await store.setUser(user);
    expect((await store.getUser())?.toJson(), user.toJson());
  });

  test('a saved login that no longer parses is treated as signed out and removed', () async {
    keychain.modern['keycloak_client_credentials'] = '{not json';
    const store = SecureStorageAuthCredentialsStore();

    expect(await store.getCredentials(), isNull);
    expect(keychain.modern, isNot(contains('keycloak_client_credentials')));
  });

  test('the client names its store after its client, realm and server', () {
    final config = ClientConfig(baseUrl: 'http://localhost:8080', realm: 'crm', clientId: 'crm-app');
    expect(KeycloakClient.storageNamespace(config), 'keycloak_client:crm-app@crm/localhost:8080');
  });
}
