library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import 'src/enums/auth_state.dart';
import 'src/enums/log_level.dart';
import 'src/exceptions/keycloak_exception.dart';
import 'src/models/user_info.dart';
import 'src/models/user_credentials.dart';
import 'src/utilities/auth_api_client.dart';
import 'src/utilities/credentials_storage.dart';

export 'src/enums/auth_state.dart';
export 'src/enums/log_level.dart';
export 'src/models/user_credentials.dart';
export 'src/models/user_info.dart';
export 'src/exceptions/keycloak_exception.dart';
export 'src/utilities/credentials_storage.dart' show ICredentialsStorage;
export 'src/utilities/auth_api_client.dart' show IAuthApiClient;

/// Keycloak client for handling authentication, token management, and user sessions.
final class KeycloakClient {
  final _authBroadcast = StreamController<AuthState>.broadcast();
  final _userBroadcast = StreamController<UserInfo?>.broadcast();

  late final ICredentialsStorage _credentialsStorage;
  late final IAuthApiClient _apiClient;
  late final Logger _logger;

  Dio? _dioClient;
  Completer<void>? _initCompleter;
  Completer<UserCredentials?>? _refreshCompleter;
  AuthState _authState = AuthState.unknown;
  UserInfo? _currentUser;
  Timer? _refreshTimer;
  Timer? _retryTimer;
  bool _initialized = false;
  bool _disposed = false;

  KeycloakClient({
    LogLevel logLevel = LogLevel.trace,
    List<String> scopes = const ['openid', 'email', 'profile'],
    required String baseUrl,
    required String redirectUri,
    required String clientId,
    required String realm,
  }) {
    _createLogger(logLevel);
    _credentialsStorage = const CredentialsStorage();
    _dioClient = Dio(
      BaseOptions(connectTimeout: const Duration(seconds: 10), receiveTimeout: const Duration(seconds: 10), sendTimeout: const Duration(seconds: 10)),
    );
    _apiClient = AuthApiClient(dioClient: _dioClient!, baseUrl: baseUrl, realm: realm, clientId: clientId, redirectUri: redirectUri, scopes: scopes);
  }

  @visibleForTesting
  KeycloakClient.withDependencies({
    LogLevel logLevel = LogLevel.trace,
    required IAuthApiClient apiClient,
    required ICredentialsStorage credentialsStorage,
  }) {
    _apiClient = apiClient;
    _credentialsStorage = credentialsStorage;
    _createLogger(logLevel);
  }

  void _createLogger(LogLevel logLevel) {
    _logger = Logger(
      printer: PrettyPrinter(methodCount: 0, errorMethodCount: 5, lineLength: 80, colors: true),
      level: switch (logLevel) {
        LogLevel.trace => Level.trace,
        LogLevel.debug => Level.debug,
        LogLevel.info => Level.info,
        LogLevel.warning => Level.warning,
        LogLevel.error => Level.error,
        LogLevel.fatal => Level.fatal,
        _ => Level.off,
      },
    );
  }

  UserInfo? get currentUser => _currentUser;
  AuthState get authState => _authState;

  Stream<UserInfo?> get onUserChange {
    _assertNotDisposed();

    final controller = StreamController<UserInfo?>();
    StreamSubscription<UserInfo?>? subscription;

    controller.onListen = () async {
      await waitForInitialization();
      if (controller.isClosed) return;
      controller.add(currentUser);
      subscription = _userBroadcast.stream.listen(
        (event) { if (!controller.isClosed) controller.add(event); },
        onError: (Object e, StackTrace st) { if (!controller.isClosed) controller.addError(e, st); },
        onDone: () { if (!controller.isClosed) controller.close(); },
      );
    };
    controller.onCancel = () async {
      await subscription?.cancel();
      if (!controller.isClosed) controller.close();
    };
    return controller.stream;
  }

  Stream<AuthState> get onAuthChange {
    _assertNotDisposed();

    final controller = StreamController<AuthState>();
    StreamSubscription<AuthState>? subscription;

    controller.onListen = () async {
      await waitForInitialization();
      if (controller.isClosed) return;
      controller.add(authState);
      subscription = _authBroadcast.stream.listen(
        (event) { if (!controller.isClosed) controller.add(event); },
        onError: (Object e, StackTrace st) { if (!controller.isClosed) controller.addError(e, st); },
        onDone: () { if (!controller.isClosed) controller.close(); },
      );
    };
    controller.onCancel = () async {
      await subscription?.cancel();
      if (!controller.isClosed) controller.close();
    };
    return controller.stream;
  }

  Future<bool> waitForInitialization() async {
    _assertNotDisposed();

    try {
      await initialize();
      return true;
    } catch (error) {
      _logger.e("Initialization failed");
      return false;
    }
  }

  void _startRefreshTimer(UserCredentials credentials) {
    _refreshTimer?.cancel();
    _retryTimer?.cancel();

    var duration = credentials.accessTokenExpiry.difference(DateTime.now()) - const Duration(minutes: 1);
    if (duration <= Duration.zero) {
      duration = const Duration(seconds: 5);
    }

    _logger.i("Scheduling token refresh in ${duration.inMinutes}m ${duration.inSeconds % 60}s");

    _refreshTimer = Timer(duration, _attemptRefresh);
  }

  Future<UserCredentials?> _attemptRefresh() {
    if (_refreshCompleter != null && !_refreshCompleter!.isCompleted) {
      return _refreshCompleter!.future;
    }

    _refreshCompleter = Completer<UserCredentials?>();
    _doRefresh().then(
      (result) => _refreshCompleter!.complete(result),
      onError: (Object e, StackTrace st) => _refreshCompleter!.complete(null),
    );

    return _refreshCompleter!.future;
  }

  Future<UserCredentials?> _doRefresh() async {
    _logger.i("Attempting token refresh");

    try {
      final credentials = await _performRefresh();
      await _credentialsStorage.setCredentials(credentials);
      _onAuthChange(AuthState.signedIn);
      _startRefreshTimer(credentials);
      _logger.i("Token refresh successful");
      return credentials;
    } on KeycloakSessionExpiredException {
      _logger.w("Session expired, re-authentication required");
      _onAuthChange(AuthState.sessionExpired);
      return null;
    } on KeycloakNetworkException {
      _logger.w("Token refresh failed due to network error, retrying in 30s");
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 30), _attemptRefresh);
      return null;
    } on KeycloakServerException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403) {
        _logger.w("Server returned ${e.statusCode}, session expired");
        _onAuthChange(AuthState.sessionExpired);
      } else {
        _logger.e("Token refresh failed with server error ${e.statusCode}, retrying in 30s");
        _retryTimer?.cancel();
        _retryTimer = Timer(const Duration(seconds: 30), _attemptRefresh);
      }
      return null;
    }
  }

  Future<UserCredentials> _performRefresh() async {
    final current = await _credentialsStorage.getCredentials();
    if (current == null || current.isRefreshExpired) {
      throw const KeycloakSessionExpiredException();
    }

    _logger.i('Performing token refresh');
    return await _apiClient.exchangeRefreshToken(current.refreshToken);
  }

  void _onAuthChange(AuthState state) {
    if (_authState == state) return;
    _logger.i("Authentication state changed: $_authState -> $state");
    _authState = state;
    _authBroadcast.add(_authState);
  }

  void _onUserChange(UserInfo? user) {
    if (_currentUser?.id == user?.id) return;
    _logger.i("User data changed: ${_currentUser?.id ?? 'null'} -> ${user?.id ?? 'null'}");
    _currentUser = user;
    _userBroadcast.add(_currentUser);
  }

  Future<void> initialize() {
    _assertNotDisposed();

    if (_initialized) {
      return Future.value();
    }

    if (_initCompleter != null && !_initCompleter!.isCompleted) {
      return _initCompleter!.future;
    }

    _logger.i("Initializing KeycloakClient");

    _initCompleter = Completer<void>();

    Future(() async {
          final credentials = await _credentialsStorage.getCredentials();
          final user = await _credentialsStorage.getUser();

          if (credentials == null || user == null) {
            _logger.i("No stored credentials or user found. User needs to sign in.");
            _onAuthChange(AuthState.signedOut);
            return;
          }

          if (credentials.isRefreshExpired) {
            _logger.i("Stored refresh token is expired. User needs to sign in again.");
            await _credentialsStorage.clear();
            _onAuthChange(AuthState.sessionExpired);
            _onUserChange(null);
            return;
          }

          _onUserChange(user);

          if (credentials.isAccessExpired) {
            _logger.i("Access token expired, will refresh");
            final refreshed = await _attemptRefresh();
            if (refreshed == null && _authState != AuthState.sessionExpired) {
              _onAuthChange(AuthState.signedIn);
            }
          } else {
            _onAuthChange(AuthState.signedIn);
            _startRefreshTimer(credentials);
          }

          _reloadUser().ignore();
        })
        .then((_) {
          _initialized = true;
          _initCompleter!.complete();
          _logger.i("KeycloakClient initialized successfully");
        })
        .catchError((error, stackTrace) {
          _logger.e("KeycloakClient initialization failed");
          _initCompleter!.completeError(error, stackTrace);
        });

    return _initCompleter!.future;
  }

  /// Opens the system browser for Keycloak's login page and completes the Authorization Code flow.
  /// Returns normally if the user cancels. Throws [KeycloakNetworkException] or [KeycloakServerException] on failure.
  Future<void> login() async {
    _assertInitialized();
    _assertNotDisposed();

    _logger.i("Initiating login flow for user.");

    try {
      final code = await _apiClient.getVerificationCode();
      if (code == null) {
        _logger.w("Login flow was cancelled by the user.");
        return;
      }
      final credentials = await _apiClient.exchangeCodeForToken(code);
      await _credentialsStorage.setCredentials(credentials);
      _startRefreshTimer(credentials);
      _onAuthChange(AuthState.signedIn);
      await reloadUser();
      _logger.i("Login flow completed successfully for user: ${currentUser?.id ?? 'unknown'}");
    } catch (error) {
      _logger.e("Login flow failed.");
      rethrow;
    }
  }

  Future<void> logout() async {
    _assertInitialized();
    _assertNotDisposed();

    _logger.i("Attempting to log out user: ${currentUser?.id ?? 'unknown'}");

    _refreshTimer?.cancel();
    _retryTimer?.cancel();

    try {
      final credentials = await _credentialsStorage.getCredentials();
      if (credentials != null) {
        await _apiClient.logout(credentials.idToken);
      }
      _logger.i("User logged out successfully.");
    } catch (error) {
      _logger.e("Logout server notification failed (continuing with local logout).");
    }

    await _credentialsStorage.clear();
    _onAuthChange(AuthState.signedOut);
    _onUserChange(null);
  }

  /// Fetches the latest user profile from the Keycloak userinfo endpoint.
  /// Throws [KeycloakNetworkException] or [KeycloakServerException] on failure.
  Future<UserInfo?> reloadUser() async {
    _assertInitialized();
    return _reloadUser();
  }

  Future<UserInfo?> _reloadUser() async {
    _assertNotDisposed();

    _logger.i("Reloading user data for current session.");

    try {
      final accessToken = await getAuthToken();
      if (accessToken == null) {
        _logger.w("Cannot reload user data because access token is not available.");
        return null;
      }
      final user = await _apiClient.getUserInfo(accessToken);
      await _credentialsStorage.setUser(user);
      _onUserChange(user);
      _logger.i("User data reloaded successfully for user: ${user.id}");
      return user;
    } catch (error) {
      _logger.e("Reloading user failed.");
      rethrow;
    }
  }

  /// Returns a valid access token, refreshing inline if expired.
  ///
  /// Returns `null` only when no session exists or the session has expired
  /// beyond recovery (refresh token expired / revoked).
  Future<String?> getAuthToken() async {
    _assertNotDisposed();

    await waitForInitialization();

    final current = await _credentialsStorage.getCredentials();
    if (current == null) return null;

    if (!current.isAccessExpired) {
      return current.accessToken;
    }

    final refreshed = await _attemptRefresh();
    return refreshed?.accessToken;
  }

  void _assertInitialized() {
    if (!_initialized) {
      throw StateError("KeycloakClient instance has not been initialized. Call initialize() and wait for it to complete before using other methods.");
    }
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError("KeycloakClient instance has been disposed and can no longer be used.");
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;

    _logger.i("Disposing KeycloakClient instance");
    _authBroadcast.close();
    _userBroadcast.close();
    _refreshTimer?.cancel();
    _retryTimer?.cancel();
    _dioClient?.close();
  }
}
