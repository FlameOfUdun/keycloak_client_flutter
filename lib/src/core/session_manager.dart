import 'dart:async';

import '../enums/auth_state.dart';
import '../models/user_info.dart';

/// Owns all identity state: who is the user, what is the auth state.
/// Has no knowledge of network or token operations.
final class SessionManager {
  final _authBroadcast = StreamController<AuthState>.broadcast();
  final _userBroadcast = StreamController<UserInfo?>.broadcast();

  AuthState _authState = AuthState.unknown;
  UserInfo? _currentUser;

  AuthState get authState => _authState;
  UserInfo? get currentUser => _currentUser;

  Stream<AuthState> get authStream => _authBroadcast.stream;
  Stream<UserInfo?> get userStream => _userBroadcast.stream;

  /// Called when a session has been established (login or successful refresh after init).
  void beginSession(UserInfo user) {
    _emitUser(user);
    _emitAuthState(AuthState.signedIn);
  }

  /// Called only on authoritative session termination: explicit logout,
  /// invalid_grant, ExpirationException, or local refresh-token expiry.
  void endSession(AuthState reason) {
    _emitUser(null);
    _emitAuthState(reason);
  }

  /// Called when fresh user profile data arrives from the server.
  /// Always emits — callers only invoke this when the data has actually changed.
  void updateUser(UserInfo user) {
    _currentUser = user;
    _userBroadcast.add(user);
  }

  void _emitAuthState(AuthState state) {
    if (_authState == state) return;
    _authState = state;
    _authBroadcast.add(state);
  }

  void _emitUser(UserInfo? user) {
    if (_currentUser?.id == user?.id) return;
    _currentUser = user;
    _userBroadcast.add(user);
  }

  void dispose() {
    _authBroadcast.close();
    _userBroadcast.close();
  }
}
