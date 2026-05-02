import '../models/user_credentials.dart';
import '../models/user_info.dart';

/// Interface for credentials storage, defining methods for saving and retrieving user information and authentication data.
abstract interface class IAuthCredentialsStore {
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
