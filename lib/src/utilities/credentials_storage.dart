import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/user_info.dart';
import '../models/user_credentials.dart';

/// Interface for credentials storage, defining methods for saving and retrieving user information and authentication data.
abstract interface class ICredentialsStorage {
  /// Retrieves the stored user information. Returns null if no user data is found.
  Future<UserInfo?> getUser();

  /// Saves the user information to secure storage. If [user] is null, it deletes the stored user data.
  Future<void> setUser(UserInfo? user);

  /// Retrieves the stored user credentials (e.g. access token, refresh token). Returns null if no credentials are found.
  Future<UserCredentials?> getCredentials();

  /// Saves the user credentials to secure storage. If [data] is null, it deletes the stored credentials.
  Future<void> setCredentials(UserCredentials? data);

  /// Clears all stored credentials and user data.
  Future<void> clear();
}

/// Credentials storage for saving and retrieving user information and authentication data.
final class CredentialsStorage implements ICredentialsStorage {
  final _storage = const FlutterSecureStorage();

  final _userKey = 'keycloak_client_user';
  final _tokenKey = 'keycloak_client_credentials';

  const CredentialsStorage();

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
      await _storage.write(
        key: _userKey,
        value: jsonEncode(user.toJson()),
      );
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
      return _storage.write(
        key: _tokenKey,
        value: jsonEncode(data.toJson()),
      );
    }
  }
}
