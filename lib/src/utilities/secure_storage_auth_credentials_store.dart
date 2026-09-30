import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';

import '../interfaces/auth_credentials_store.dart';
import '../models/keycloak_exception.dart';
import '../models/user_info.dart';
import '../models/user_credentials.dart';

/// Credentials storage for saving and retrieving user information and authentication data, in the platform's secure
/// storage (`flutter_secure_storage`).
///
/// **macOS.** The modern data-protection keychain only accepts apps signed with a `keychain-access-groups`
/// entitlement; unsigned and development builds are refused (error -34018). Unless [storage] is given, the first use
/// checks which keychain works — the data-protection keychain when the app is entitled, otherwise the login keychain —
/// and keeps that choice for the rest of the run. A signed app never falls back.
///
/// The login keychain is shared by every app on the Mac, so there the items go under [namespace] (the keychain's
/// service name): one app's saved login never meets another's. [KeycloakClient] names it after its client, realm and
/// server.
///
/// **Every platform.** The first use proves the storage can be written, so a device where nothing works fails at
/// start-up ([KeycloakClient.initialize]) with a [KeycloakStorageException] rather than after a successful login. A
/// saved login that can't be read back (an item another build of the app made, which the keychain won't show this one,
/// or one that no longer parses) is treated as no saved login: the user signs in again rather than the app failing.
final class SecureStorageAuthCredentialsStore implements IAuthCredentialsStore {
  /// With [storage], exactly that storage is used and nothing is chosen for you.
  const SecureStorageAuthCredentialsStore({FlutterSecureStorage? storage, this.namespace}) : _explicit = storage;

  final FlutterSecureStorage? _explicit;

  /// The login keychain's service name for this app's items (macOS only); flutter_secure_storage's default when null.
  final String? namespace;

  static const _userKey = 'keycloak_client_user';
  static const _tokenKey = 'keycloak_client_credentials';
  static const _probeKey = 'keycloak_client_probe';

  static final _logger = Logger('KeycloakClient.Storage');

  /// The chosen default storage for each namespace, decided once per run.
  static final _chosen = <String?, Future<FlutterSecureStorage>>{};

  /// Forgets the chosen storage, so the next use checks again. For tests.
  @visibleForTesting
  static void resetForTesting() => _chosen.clear();

  Future<FlutterSecureStorage> get _storage {
    if (_explicit case final storage?) return Future.value(storage);
    // A failed choice is not kept: the next use (a retry) checks again.
    return _chosen[namespace] ??= _choose(namespace)..catchError((_) {
      _chosen.remove(namespace);
      return const FlutterSecureStorage();
    });
  }

  static Future<FlutterSecureStorage> _choose(String? namespace) async {
    const standard = FlutterSecureStorage();
    final isMacOS = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    try {
      await _probe(standard);
      return standard;
    } on PlatformException catch (e) {
      if (!isMacOS) throw _unusable(e);
      final login = FlutterSecureStorage(
        mOptions: MacOsOptions(usesDataProtectionKeychain: false, accountName: namespace ?? AppleOptions.defaultAccountName),
      );
      try {
        await _probe(login);
      } on PlatformException catch (e2) {
        throw _unusable(e2);
      }
      _logger.info(
        'The data-protection keychain is not available to this app (${e.code}: ${e.message}), '
        'most likely because it is not signed with a keychain-access-groups entitlement. '
        'Using the login keychain instead.',
      );
      return login;
    }
  }

  static Future<void> _probe(FlutterSecureStorage storage) async {
    await storage.write(key: _probeKey, value: '1');
    await storage.delete(key: _probeKey);
  }

  static KeycloakStorageException _unusable(PlatformException e) => KeycloakStorageException(
        defaultTargetPlatform == TargetPlatform.macOS && !kIsWeb
            ? 'No keychain on this Mac accepts the app (${e.code}). Sign it with a keychain-access-groups '
                'entitlement, or pass SecureStorageAuthCredentialsStore(storage: ...).'
            : 'Secure storage cannot be written on this device (${e.code}).',
        cause: e,
      );

  /// Runs [action] on the chosen storage, reporting a storage failure as a [KeycloakStorageException].
  Future<T> _use<T>(Future<T> Function(FlutterSecureStorage storage) action) async {
    final storage = await _storage;
    try {
      return await action(storage);
    } on PlatformException catch (e) {
      throw KeycloakStorageException('Secure storage failed (${e.code}: ${e.message}).', cause: e);
    }
  }

  /// A saved value, or null when there is none or it can't be used; an unusable one is removed if it can be, so
  /// the next save starts clean. Storage that can't be reached at all still fails ([KeycloakStorageException]).
  Future<T?> _readSaved<T>(String key, T Function(Map<String, dynamic> json) parse) async {
    final storage = await _storage;
    String? encoded;
    try {
      encoded = await storage.read(key: key);
    } on PlatformException catch (e) {
      _logger.warning('The saved $key can\'t be read (${e.code}: ${e.message}); starting signed out.');
      await _forget(storage, key);
      return null;
    }
    if (encoded == null) return null;
    try {
      return parse(jsonDecode(encoded) as Map<String, dynamic>);
    } on Object catch (e) {
      _logger.warning('The saved $key is not usable ($e); starting signed out.');
      await _forget(storage, key);
      return null;
    }
  }

  static Future<void> _forget(FlutterSecureStorage storage, String key) async {
    try {
      await storage.delete(key: key);
    } on PlatformException catch (e) {
      _logger.warning('The unusable $key could not be removed (${e.code}); the next save replaces it if it can.');
    }
  }

  @override
  Future<UserInfo?> getUser() => _readSaved(_userKey, UserInfo.fromJson);

  @override
  Future<void> setUser(UserInfo? user) => _use((s) => user == null
      ? s.delete(key: _userKey)
      : s.write(key: _userKey, value: jsonEncode(user.toJson())));

  @override
  Future<void> clear() => _use((s) async {
        await s.delete(key: _userKey);
        await s.delete(key: _tokenKey);
      });

  @override
  Future<UserCredentials?> getCredentials() => _readSaved(_tokenKey, UserCredentials.fromJson);

  @override
  Future<void> setCredentials(UserCredentials? data) => _use((s) => data == null
      ? s.delete(key: _tokenKey)
      : s.write(key: _tokenKey, value: jsonEncode(data.toJson())));
}
