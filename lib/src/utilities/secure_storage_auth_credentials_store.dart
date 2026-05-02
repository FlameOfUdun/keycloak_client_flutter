import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../interfaces/auth_credentials_store.dart';
import '../models/user_info.dart';
import '../models/user_credentials.dart';

/// Credentials storage for saving and retrieving user information and authentication data.
final class SecureStorageAuthCredentialsStore implements IAuthCredentialsStore {
  final _storage = const FlutterSecureStorage();

  final _userKey = 'keycloak_client_user';
  final _tokenKey = 'keycloak_client_credentials';

  const SecureStorageAuthCredentialsStore();

  @override
  Future<UserInfo?> getUser() async {
    final encoded = await _storage.read(key: _userKey);
    if (encoded == null) return null;
    final data = jsonDecode(encoded) as Map<String, dynamic>;
    return UserInfo.fromJson(data);
  }

  @override
  Future<void> setUser(UserInfo? user) async {
    if (user == null) {
      await _storage.delete(key: _userKey);
    } else {
      await _storage.write(key: _userKey, value: jsonEncode(user.toJson()));
    }
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _userKey);
    await _storage.delete(key: _tokenKey);
  }

  @override
  Future<UserCredentials?> getCredentials() async {
    final encoded = await _storage.read(key: _tokenKey);
    if (encoded == null) return null;
    final data = jsonDecode(encoded) as Map<String, dynamic>;
    return UserCredentials.fromJson(data);
  }

  @override
  Future<void> setCredentials(UserCredentials? data) {
    if (data == null) {
      return _storage.delete(key: _tokenKey);
    } else {
      return _storage.write(key: _tokenKey, value: jsonEncode(data.toJson()));
    }
  }
}
