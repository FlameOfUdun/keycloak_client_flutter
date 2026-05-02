library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:oauth2/oauth2.dart';

import 'src/enums/auth_state.dart';
import 'src/enums/log_level.dart';
import 'src/interfaces/auth_credentials_store.dart';
import 'src/models/client_config.dart';
import 'src/models/keycloak_exception.dart';
import 'src/models/platform_config.dart';
import 'src/models/user_credentials.dart';
import 'src/models/user_info.dart';
import 'src/interfaces/login_strategy.dart';
import 'src/strategies/platform_login_strategy.dart';
import 'src/utilities/secure_storage_auth_credentials_store.dart';

export 'src/enums/auth_state.dart';
export 'src/enums/log_level.dart';
export 'src/models/client_config.dart';
export 'src/models/keycloak_exception.dart';
export 'src/models/user_credentials.dart';
export 'src/models/user_info.dart';
export 'src/models/platform_config.dart';
export 'src/interfaces/login_strategy.dart';
export 'src/interfaces/auth_credentials_store.dart';
export 'src/interfaces/pending_grant_store.dart';

/// Keycloak client for handling authentication, token management, and user
/// sessions across all platforms.
final class KeycloakClient {
  final _authBroadcast = StreamController<AuthState>.broadcast();
  final _userBroadcast = StreamController<UserInfo?>.broadcast();

  late final IAuthCredentialsStore _credentialsStorage;
  late final ILoginStrategy _loginStrategy;
  late final Logger _logger;

  final ClientConfig _clientConfig;

  Client? _oauthClient;
  Completer<void>? _initCompleter;
  Completer<bool>? _refreshCompleter;
  AuthState _authState = AuthState.unknown;
  UserInfo? _currentUser;
  Timer? _refreshTimer;
  bool _initialized = false;
  bool _disposed = false;

  String get _clientId => _clientConfig.clientId;
  List<String> get _scopes => _clientConfig.scopes;
  WebConfig get _webConfig => _clientConfig.web;
  DesktopConfig get _desktopConfig => _clientConfig.desktop;
  MobileConfig get _mobileConfig => _clientConfig.mobile;

  /// Creates a [KeycloakClient] from a single configuration object.
  KeycloakClient({required ClientConfig config})
    : _clientConfig = config,
      _credentialsStorage = const SecureStorageAuthCredentialsStore(),
      _loginStrategy = defaultLoginStrategy {
    _createLogger(config.logLevel);
  }

  @visibleForTesting
  KeycloakClient.withDependencies({
    required ClientConfig config,
    required IAuthCredentialsStore credentialsStorage,
    IDesktopLoginStrategy? desktopLoginStrategy,
    IMobileLoginStrategy? mobileLoginStrategy,
    IWebLoginStrategy? webLoginStrategy,
  }) : _clientConfig = config,
       _credentialsStorage = credentialsStorage,
       _loginStrategy = _selectLoginStrategy(
         desktopOverride: desktopLoginStrategy,
         mobileOverride: mobileLoginStrategy,
         webOverride: webLoginStrategy,
       ) {
    _createLogger(config.logLevel);
  }

  static ILoginStrategy _selectLoginStrategy({
    IDesktopLoginStrategy? desktopOverride,
    IMobileLoginStrategy? mobileOverride,
    IWebLoginStrategy? webOverride,
  }) {
    final strategy = defaultLoginStrategy;
    return switch (strategy) {
      IDesktopLoginStrategy() => desktopOverride ?? strategy,
      IMobileLoginStrategy() => mobileOverride ?? strategy,
      IWebLoginStrategy() => webOverride ?? strategy,
      _ => throw StateError('Unknown login strategy type: ${strategy.runtimeType}'),
    };
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

  /// Emits the current [UserInfo] immediately on listen, then on every change.
  Stream<UserInfo?> get onUserChange => _bufferedStream(_userBroadcast, () => currentUser);

  /// Emits the current [AuthState] immediately on listen, then on every change.
  Stream<AuthState> get onAuthChange => _bufferedStream(_authBroadcast, () => authState);

  Stream<T> _bufferedStream<T>(StreamController<T> broadcast, T Function() current) {
    _assertNotDisposed();
    final controller = StreamController<T>();
    StreamSubscription<T>? sub;
    controller.onListen = () async {
      await waitForInitialization();
      if (controller.isClosed) return;
      controller.add(current());
      sub = broadcast.stream.listen(
        (e) {
          if (!controller.isClosed) controller.add(e);
        },
        onError: (e, st) {
          if (!controller.isClosed) controller.addError(e, st);
        },
        onDone: () {
          if (!controller.isClosed) controller.close();
        },
      );
    };
    controller.onCancel = () async {
      await sub?.cancel();
      if (!controller.isClosed) controller.close();
    };
    return controller.stream;
  }

  Future<bool> waitForInitialization() async {
    _assertNotDisposed();
    try {
      await initialize();
      return true;
    } catch (_) {
      _logger.e('Initialization failed');
      return false;
    }
  }

  Future<void> initialize() {
    _assertNotDisposed();
    if (_initialized) return Future.value();
    if (_initCompleter != null && !_initCompleter!.isCompleted) return _initCompleter!.future;

    _logger.i('Initializing KeycloakClient');
    _initCompleter = Completer<void>();

    Future(() async {
          final stored = await _credentialsStorage.getCredentials();
          final user = await _credentialsStorage.getUser();

          if (stored == null || user == null) {
            _logger.i('No stored credentials. User needs to sign in.');
            _onAuthChange(AuthState.signedOut);
            return;
          }

          if (stored.isRefreshExpired) {
            _logger.i('Refresh token expired. Clearing session.');
            await _credentialsStorage.clear();
            _onAuthChange(AuthState.sessionExpired);
            _onUserChange(null);
            return;
          }

          _oauthClient = Client(stored.toOAuth2Credentials(_clientConfig.tokenEndpoint), identifier: _clientId);
          _onUserChange(user);

          if (stored.isAccessExpired) {
            _logger.i('Access token expired, refreshing on init.');
            final ok = await _attemptRefresh();
            if (!ok && _authState != AuthState.sessionExpired) {
              _onAuthChange(AuthState.signedIn);
            }
          } else {
            _onAuthChange(AuthState.signedIn);
            _scheduleRefresh(stored);
          }

          _reloadUser().ignore();
        })
        .then((_) {
          _initialized = true;
          _initCompleter!.complete();
          _logger.i('KeycloakClient initialized.');
        })
        .catchError((e, st) {
          _logger.e('KeycloakClient initialization failed.');
          _initCompleter!.completeError(e, st);
        });

    return _initCompleter!.future;
  }

  /// Starts the login flow using the platform's [ILoginStrategy].
  ///
  /// - Desktop: opens system browser, captures callback via localhost server
  /// - Mobile:  opens system browser, captures callback via deep link
  /// - Web:     redirects the current tab; on web, this future never
  ///            completes — the tab is unloading. Call [handleWebCallback]
  ///            on the next page load to finalise the session.
  ///
  /// Returns normally (without throwing) if the user cancels.
  Future<void> login() async {
    _assertInitialized();
    _assertNotDisposed();

    _logger.i('Initiating login flow via ${_loginStrategy.runtimeType}.');

    final client = await switch (_loginStrategy) {
      final IDesktopLoginStrategy strategy => strategy.login(platformConfig: _desktopConfig, clientConfig: _clientConfig),
      final IMobileLoginStrategy strategy => strategy.login(platformConfig: _mobileConfig, clientConfig: _clientConfig),
      final IWebLoginStrategy strategy => strategy.login(platformConfig: _webConfig, clientConfig: _clientConfig),
      _ => throw StateError('Unknown login strategy type: ${_loginStrategy.runtimeType}'),
    };

    if (client == null) {
      _logger.w('Login cancelled by user.');
      return;
    }

    await _finalizeLogin(client);
    _logger.i('Login successful: ${currentUser?.id ?? 'unknown'}');
  }

  Future<void> _finalizeLogin(Client client) async {
    _oauthClient = client;
    final credentials = UserCredentials.fromOAuth2(client.credentials);
    await _credentialsStorage.setCredentials(credentials);
    _scheduleRefresh(credentials);
    _onAuthChange(AuthState.signedIn);
    await _reloadUser();
  }

  /// **Web only.** Call this once on app startup with the current page URI
  /// so the web login strategy can complete any in-progress redirect flow.
  ///
  /// Returns `true` when a pending grant was found and a session was
  /// established; returns `false` when the URI carried no matching grant
  /// (i.e. this was a normal page load, not a callback).
  ///
  /// Throws [KeycloakTimeoutException] if a matching grant existed but
  /// the user took longer than the store's TTL to return.
  ///
  /// ```dart
  /// // In main() or your initial route:
  /// await KeycloakClient.handleWebCallback(Uri.base);
  /// ```
  Future<bool> handleWebCallback(Uri uri) async {
    _assertNotDisposed();
    final strategy = _loginStrategy;
    if (strategy is! IWebLoginStrategy) {
      throw StateError('handleWebCallback can only be used with WebLoginStrategy.');
    }

    // Ensure the client has initialised first so the post-callback
    // _finalizeLogin path does not race a concurrent initialize() that
    // would observe credentials-without-user and flip state to signedOut.
    await waitForInitialization();

    final client = await strategy.handleCallback(uri);
    if (client == null) return false;

    await _finalizeLogin(client);
    _logger.i('Web login resumed: ${currentUser?.id ?? 'unknown'}');
    return true;
  }

  Future<void> logout() async {
    _assertInitialized();
    _assertNotDisposed();

    _logger.i('Logging out: ${currentUser?.id ?? 'unknown'}');
    _refreshTimer?.cancel();

    try {
      final stored = await _credentialsStorage.getCredentials();
      if (stored != null && _oauthClient != null) {
        await _oauthClient!.post(
          _clientConfig.logoutEndpoint,
          body: {'client_id': _clientId, 'refresh_token': stored.refreshToken, if (stored.idToken != null) 'id_token_hint': stored.idToken!},
        );
      }
    } catch (_) {
      _logger.e('Logout server notification failed (continuing local logout).');
    }

    _oauthClient?.close();
    _oauthClient = null;
    await _credentialsStorage.clear();
    _onAuthChange(AuthState.signedOut);
    _onUserChange(null);
    _logger.i('User logged out.');
  }

  /// Fetches the latest user profile from the Keycloak userinfo endpoint.
  Future<UserInfo?> reloadUser() async {
    _assertInitialized();
    return _reloadUser();
  }

  Future<UserInfo?> _reloadUser() async {
    _assertNotDisposed();
    _logger.i('Reloading user data.');

    try {
      final token = await getAuthToken();
      if (token == null) {
        _logger.w('No access token available to reload user.');
        return null;
      }
      final response = await _oauthClient!.get(_clientConfig.userInfoEndpoint);
      if (response.statusCode != 200) {
        throw KeycloakServerException(response.statusCode, 'UserInfo request failed');
      }
      final user = UserInfo.fromApi(jsonDecode(response.body) as Map<String, dynamic>);
      await _credentialsStorage.setUser(user);
      _onUserChange(user);
      _logger.i('User data reloaded: ${user.id}');
      return user;
    } catch (e) {
      _logger.e('Reloading user failed.');
      rethrow;
    }
  }
  /// Returns a valid access token, refreshing inline if expired.
  /// Returns `null` when no session exists or the session cannot be recovered.
  Future<String?> getAuthToken() async {
    _assertNotDisposed();
    await waitForInitialization();

    final stored = await _credentialsStorage.getCredentials();
    if (stored == null) return null;
    if (!stored.isAccessExpired) return stored.accessToken;

    final ok = await _attemptRefresh();
    if (!ok) return null;

    return (await _credentialsStorage.getCredentials())?.accessToken;
  }

  void _scheduleRefresh(UserCredentials credentials, {bool isRetry = false}) {
    _refreshTimer?.cancel();

    final duration = isRetry
        ? const Duration(seconds: 30)
        : () {
            final d = credentials.accessTokenExpiry.difference(DateTime.now()) - const Duration(minutes: 1);
            return d <= Duration.zero ? const Duration(seconds: 5) : d;
          }();

    _logger.i(isRetry ? 'Retry scheduled in 30s' : 'Token refresh in ${duration.inMinutes}m ${duration.inSeconds % 60}s');

    _refreshTimer = Timer(duration, _attemptRefresh);
  }

  Future<bool> _attemptRefresh() {
    if (_refreshCompleter != null && !_refreshCompleter!.isCompleted) {
      return _refreshCompleter!.future;
    }
    _refreshCompleter = Completer<bool>();
    _doRefresh().then(_refreshCompleter!.complete, onError: (_, _) => _refreshCompleter!.complete(false));
    return _refreshCompleter!.future;
  }

  Future<bool> _doRefresh() async {
    _logger.i('Attempting token refresh.');

    try {
      if (_oauthClient == null) throw const KeycloakSessionExpiredException();

      _oauthClient = await _oauthClient!.refreshCredentials(_scopes);

      final credentials = UserCredentials.fromOAuth2(_oauthClient!.credentials);
      await _credentialsStorage.setCredentials(credentials);
      _onAuthChange(AuthState.signedIn);
      _scheduleRefresh(credentials);
      _logger.i('Token refresh successful.');
      return true;
    } on ExpirationException {
      _logger.w('Session expired, re-authentication required.');
      _onAuthChange(AuthState.sessionExpired);
      return false;
    } on AuthorizationException catch (e) {
      if (e.error == 'invalid_grant') {
        _logger.w('Refresh token revoked or expired.');
        _onAuthChange(AuthState.sessionExpired);
      } else {
        _logger.e('Authorization error during refresh, retrying in 30s.');
        final stored = await _credentialsStorage.getCredentials();
        if (stored != null) _scheduleRefresh(stored, isRetry: true);
      }
      return false;
    } on SocketException {
      _logger.w('Network error during refresh, retrying in 30s.');
      final stored = await _credentialsStorage.getCredentials();
      if (stored != null) _scheduleRefresh(stored, isRetry: true);
      return false;
    }
  }

  void _onAuthChange(AuthState state) {
    if (_authState == state) return;
    _logger.i('Auth state: $_authState → $state');
    _authState = state;
    _authBroadcast.add(_authState);
  }

  void _onUserChange(UserInfo? user) {
    if (_currentUser?.id == user?.id) return;
    _logger.i('User: ${_currentUser?.id ?? 'null'} → ${user?.id ?? 'null'}');
    _currentUser = user;
    _userBroadcast.add(_currentUser);
  }

  void _assertInitialized() {
    if (!_initialized) {
      throw StateError('KeycloakClient has not been initialized. Call initialize() first.');
    }
  }

  void _assertNotDisposed() {
    if (_disposed) throw StateError('KeycloakClient has been disposed.');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _logger.i('Disposing KeycloakClient.');
    _authBroadcast.close();
    _userBroadcast.close();
    _refreshTimer?.cancel();
    _oauthClient?.close();
  }
}
