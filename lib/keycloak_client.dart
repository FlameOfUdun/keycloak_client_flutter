library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:oauth2/oauth2.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/core/session_manager.dart';
import 'src/core/token_service.dart';
import 'src/enums/auth_state.dart';
import 'src/enums/log_level.dart';
import 'src/enums/refresh_result.dart';
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
  late final IAuthCredentialsStore _credentialsStorage;
  late final ILoginStrategy _loginStrategy;
  late final Logger _logger;
  late final SessionManager _sessionManager;
  late final TokenService _tokenService;

  final ClientConfig _clientConfig;
  final DesktopConfig _desktopConfig;
  final MobileConfig _mobileConfig;
  final WebConfig _webConfig;
  final RefreshOperation? _tokenRefreshOperation;

  Completer<void>? _initCompleter;
  bool _initialized = false;
  bool _disposed = false;

  /// Creates a [KeycloakClient] from a single configuration object.
  KeycloakClient({
    required ClientConfig clientConfig,
    WebConfig? webConfig,
    MobileConfig? mobileConfig,
    DesktopConfig? desktopConfig,
  }) : _clientConfig = clientConfig,
       _desktopConfig = desktopConfig ?? const DesktopConfig(),
       _mobileConfig = mobileConfig ?? const MobileConfig(),
       _webConfig = webConfig ?? const WebConfig(),
       _credentialsStorage = const SecureStorageAuthCredentialsStore(),
       _tokenRefreshOperation = null,
       _loginStrategy = defaultLoginStrategy {
    _createLogger(clientConfig.logLevel);
    _createInternals();
  }

  @visibleForTesting
  KeycloakClient.withDependencies({
    required ClientConfig clientConfig,
    required IAuthCredentialsStore credentialsStorage,
    WebConfig? webConfig,
    MobileConfig? mobileConfig,
    DesktopConfig? desktopConfig,
    IDesktopLoginStrategy? desktopLoginStrategy,
    IMobileLoginStrategy? mobileLoginStrategy,
    IWebLoginStrategy? webLoginStrategy,
    RefreshOperation? tokenRefreshOperation,
  }) : _clientConfig = clientConfig,
       _desktopConfig = desktopConfig ?? const DesktopConfig(),
       _mobileConfig = mobileConfig ?? const MobileConfig(),
       _webConfig = webConfig ?? const WebConfig(),
       _credentialsStorage = credentialsStorage,
       _tokenRefreshOperation = tokenRefreshOperation,
       _loginStrategy = _selectLoginStrategy(
         desktopOverride: desktopLoginStrategy,
         mobileOverride: mobileLoginStrategy,
         webOverride: webLoginStrategy,
       ) {
    _createLogger(clientConfig.logLevel);
    _createInternals();
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
      _ => throw StateError(
        'Unknown login strategy type: ${strategy.runtimeType}',
      ),
    };
  }

  void _createLogger(LogLevel logLevel) {
    _logger = Logger(
      printer: PrettyPrinter(
        methodCount: 0,
        errorMethodCount: 5,
        lineLength: 80,
        colors: true,
      ),
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

  void _createInternals() {
    _sessionManager = SessionManager();
    _tokenService = TokenService(
      store: _credentialsStorage,
      scopes: _clientConfig.scopes,
      onPermanentFailure: () => _endSession(AuthState.sessionExpired),
      onRecovery: () => _reloadUser().ignore(),
      logger: _logger,
      refreshTimeout: _clientConfig.refreshTimeout,
      refreshOperation: _tokenRefreshOperation,
    );
  }

  UserInfo? get currentUser => _sessionManager.currentUser;
  AuthState get authState => _sessionManager.authState;

  /// Emits the current [UserInfo] immediately on listen, then on every change.
  Stream<UserInfo?> get onUserChange =>
      _bufferedStream(_sessionManager.userStream, () => currentUser);

  /// Emits the current [AuthState] immediately on listen, then on every change.
  Stream<AuthState> get onAuthChange =>
      _bufferedStream(_sessionManager.authStream, () => authState);

  Stream<T> _bufferedStream<T>(Stream<T> broadcast, T Function() current) {
    _assertNotDisposed();
    final controller = StreamController<T>();
    StreamSubscription<T>? sub;
    controller.onListen = () async {
      await waitForInitialization();
      if (controller.isClosed) return;
      controller.add(current());
      sub = broadcast.listen(
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

  /// Waits for the client to initialize, returning `true` if initialization succeeded
  /// or `false` if initialization failed. Initialization is required before most
  /// operations, but is performed automatically on first use if not called explicitly.
  Future<bool> waitForInitialization() async {
    try {
      await initialize();
      return true;
    } catch (_) {
      _logger.e('Initialization failed');
      return false;
    }
  }

  /// Initializes the client by loading stored credentials and user info, validating
  /// sessions, and setting up token refresh. This should be called once on app startup.
  ///
  /// If not called explicitly, the client will auto-initialize on first use (e.g. login or getAuthToken).
  Future<void> initialize() {
    _assertNotDisposed();
    if (_initialized) return Future.value();
    if (_initCompleter != null && !_initCompleter!.isCompleted) {
      return _initCompleter!.future;
    }

    _logger.i('Initializing KeycloakClient');
    _initCompleter = Completer<void>();

    Future(() async {
          final stored = await _credentialsStorage.getCredentials();
          final user = await _credentialsStorage.getUser();

          if (stored == null || user == null) {
            _logger.i('No stored credentials. User needs to sign in.');
            _sessionManager.endSession(AuthState.signedOut);
            return;
          }

          if (stored.isRefreshExpired) {
            _logger.i('Refresh token expired. Clearing session.');
            await _endSession(AuthState.sessionExpired);
            return;
          }

          _tokenService.setClient(
            Client(
              stored.toOAuth2Credentials(_clientConfig.tokenEndpoint),
              identifier: _clientConfig.clientId,
            ),
          );

          if (stored.isAccessExpired) {
            _logger.i('Access token expired, refreshing on init.');
            final result = await _tokenService.attemptRefresh();
            if (result is RefreshPermanentFailure) return;
            // Offline-first: start the session with the cached user profile so the
            // app is usable immediately; _reloadUser() will patch it up on recovery.
            _sessionManager.beginSession(user);
            // Only re-fetch user info when refresh actually succeeded.
            // On transient failure, onRecovery fires _reloadUser() when network returns.
            // Note: TokenService._handleTransientFailure already called scheduleRefresh.
            if (result is RefreshSuccess) _reloadUser().ignore();
          } else {
            _sessionManager.beginSession(user);
            _tokenService.scheduleRefresh(stored);
            _reloadUser().ignore();
          }
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
    await waitForInitialization();

    _logger.i('Initiating login flow via ${_loginStrategy.runtimeType}.');

    final client = await switch (_loginStrategy) {
      final IDesktopLoginStrategy strategy => strategy.login(
        platformConfig: _desktopConfig,
        clientConfig: _clientConfig,
      ),
      final IMobileLoginStrategy strategy => strategy.login(
        platformConfig: _mobileConfig,
        clientConfig: _clientConfig,
      ),
      final IWebLoginStrategy strategy => strategy.login(
        platformConfig: _webConfig,
        clientConfig: _clientConfig,
      ),
      _ => throw StateError(
        'Unknown login strategy type: ${_loginStrategy.runtimeType}',
      ),
    };

    if (client == null) {
      _logger.w('Login cancelled by user.');
      return;
    }

    await _finalizeLogin(client);
    _logger.i('Login successful: ${currentUser?.id ?? 'unknown'}');
  }

  Future<void> _finalizeLogin(Client client) async {
    _tokenService.setClient(client);
    final credentials = UserCredentials.fromOAuth2(client.credentials);
    await _credentialsStorage.setCredentials(credentials);
    final user = await _reloadUser();
    if (user == null)
      throw KeycloakServerException(0, 'Could not load user after login');
    _sessionManager.beginSession(user);
    _tokenService.scheduleRefresh(
      credentials,
    ); // armed AFTER session is fully established
  }

  /// Opens the Keycloak account console in an external browser so the user
  /// can manage their profile, credentials, sessions, and (if enabled on the
  /// realm) delete their account.
  ///
  /// Throws [KeycloakNetworkException] if the platform cannot launch a browser.
  Future<void> manageAccount() async {
    _assertNotDisposed();

    final url = _clientConfig.accountEndpoint;
    _logger.i('Opening account console: $url');

    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw const KeycloakNetworkException('Could not open account console.');
    }
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
    final strategy = _loginStrategy;
    if (strategy is! IWebLoginStrategy) {
      throw StateError(
        'handleWebCallback can only be used with WebLoginStrategy.',
      );
    }

    await waitForInitialization();

    final client = await strategy.handleCallback(uri);
    if (client == null) return false;

    await _finalizeLogin(client);
    _logger.i('Web login resumed: ${currentUser?.id ?? 'unknown'}');
    return true;
  }

  /// Logs out the current user by clearing local session and notifying the server.
  Future<void> logout() async {
    _assertNotDisposed();
    _logger.i('Logging out: ${currentUser?.id ?? 'unknown'}');

    final stored = await _credentialsStorage.getCredentials();
    if (stored != null) {
      await _tokenService.revokeSession(
        logoutEndpoint: _clientConfig.logoutEndpoint,
        clientId: _clientConfig.clientId,
        refreshToken: stored.refreshToken,
        idToken: stored.idToken,
      );
    }

    await _endSession(AuthState.signedOut);
    _logger.i('User logged out.');
  }

  Future<void> _endSession(AuthState reason) async {
    _tokenService.invalidate();
    await _credentialsStorage.clear();
    _sessionManager.endSession(reason);
  }

  /// Fetches the latest user profile from the Keycloak userinfo endpoint.
  Future<UserInfo?> reloadUser() async {
    await waitForInitialization();
    return _reloadUser();
  }

  /// Forces an immediate token refresh regardless of access token expiry,
  /// then reloads the user profile. Useful after returning from account
  /// management or when an admin has changed the user's roles and you need
  /// updated claims without waiting for the scheduled refresh.
  ///
  /// Throws [KeycloakNetworkException] if the server is unreachable.
  /// Does nothing if the session has permanently expired (streams will already
  /// have emitted [AuthState.sessionExpired]).
  Future<void> refreshToken() async {
    await waitForInitialization();
    final result = await _tokenService.attemptRefresh();
    switch (result) {
      case RefreshSuccess():
        _reloadUser().ignore();
      case RefreshTransientFailure(:final cause):
        throw KeycloakNetworkException(cause);
      case RefreshPermanentFailure():
        break; // session already ended via onPermanentFailure
    }
  }

  Future<UserInfo?> _reloadUser() async {
    _logger.i('Reloading user data.');

    try {
      final token = await getAuthToken();
      if (token == null) {
        _logger.w('No access token available to reload user.');
        return null;
      }
      final client = _tokenService.oauthClient;
      if (client == null) return null;
      final response = await client.get(_clientConfig.userInfoEndpoint);
      if (response.statusCode != 200) {
        throw KeycloakServerException(
          response.statusCode,
          'UserInfo request failed',
        );
      }
      final user = UserInfo.fromApi(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
      await _credentialsStorage.setUser(user);
      _sessionManager.updateUser(user);
      _logger.i('User data reloaded: ${user.id}');
      return user;
    } on KeycloakNetworkException {
      _logger.w('Cannot reload user — network unavailable.');
      return null;
    } catch (e, st) {
      _logger.e('Reloading user failed.', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// Returns a valid access token, refreshing inline if expired.
  /// Returns `null` when no session exists or the session cannot be recovered.
  Future<String?> getAuthToken() async {
    await waitForInitialization();

    final stored = await _credentialsStorage.getCredentials();
    if (stored == null) return null;
    if (!stored.isAccessExpired) return stored.accessToken;

    final result = await _tokenService.attemptRefresh();
    return switch (result) {
      RefreshSuccess(:final credentials) => credentials.accessToken,
      RefreshTransientFailure(:final cause) => throw KeycloakNetworkException(
        cause,
      ),
      RefreshPermanentFailure() => null,
    };
  }

  void _assertNotDisposed() {
    if (_disposed) throw StateError('KeycloakClient has been disposed.');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _logger.i('Disposing KeycloakClient.');
    _sessionManager.dispose();
    _tokenService.dispose();
  }
}
