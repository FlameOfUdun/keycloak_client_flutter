import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:oauth2/oauth2.dart' as oauth2;

import '../enums/refresh_result.dart';
import '../interfaces/auth_credentials_store.dart';
import '../models/user_credentials.dart';

/// Signature for the OAuth2 token refresh operation.
/// Injectable so tests can simulate server responses without HTTP.
typedef RefreshOperation = Future<oauth2.Client> Function(oauth2.Client current, List<String> scopes);

/// Owns all transport concerns: OAuth2 client lifetime, token refresh,
/// retry scheduling, and recovery detection.
/// Has no knowledge of AuthState or UserInfo.
final class TokenService {
  final IAuthCredentialsStore _store;
  final List<String> _scopes;
  final Logger _logger;
  final RefreshOperation _refreshOperation;
  final Duration _refreshTimeout;
  final Duration _refreshTokenLifetime;
  final bool _isOfflineSession;

  /// Called (and awaited) when the session is permanently invalid.
  final Future<void> Function() onPermanentFailure;

  /// Called when refresh transitions from failing to succeeding (network recovery).
  final void Function() onRecovery;

  /// Called after every successful refresh, once the new credentials are stored.
  ///
  /// Fires on both refresh paths — the scheduled timer and the inline refresh
  /// inside `getAuthToken()` — because both run through [attemptRefresh].
  final void Function() onTokenRefreshed;

  oauth2.Client? _oauthClient;
  Completer<RefreshResult>? _refreshCompleter;
  Timer? _refreshTimer;
  bool _previousRefreshFailed = false;

  TokenService({
    required IAuthCredentialsStore store,
    required List<String> scopes,
    required this.onPermanentFailure,
    required this.onRecovery,
    required this.onTokenRefreshed,
    required Logger logger,
    Duration refreshTimeout = const Duration(seconds: 15),
    Duration refreshTokenLifetime = const Duration(days: 30),
    bool isOfflineSession = false,
    RefreshOperation? refreshOperation,
  }) : _store = store,
       _scopes = scopes,
       _logger = logger,
       _refreshTimeout = refreshTimeout,
       _refreshTokenLifetime = refreshTokenLifetime,
       _isOfflineSession = isOfflineSession,
       _refreshOperation = refreshOperation ?? ((client, scopes) => client.refreshCredentials(scopes));

  /// Exposes the active OAuth2 client for direct HTTP calls (userinfo, logout).
  oauth2.Client? get oauthClient => _oauthClient;

  /// Sets the active OAuth2 client. Called after login or on init with stored credentials.
  void setClient(oauth2.Client client) {
    _oauthClient = client;
  }

  /// Cancels the timer and closes the OAuth2 client.
  /// Called by the facade when ending a session.
  void invalidate() {
    _refreshTimer?.cancel();
    _oauthClient?.close();
    _oauthClient = null;
  }

  /// Schedules the next refresh. Self-managing after the first successful refresh.
  /// The facade calls this once on init for non-expired tokens.
  void scheduleRefresh(UserCredentials credentials, {bool isRetry = false}) {
    _refreshTimer?.cancel();

    final duration = isRetry
        ? const Duration(seconds: 30)
        : () {
            final d = credentials.accessTokenExpiry.difference(DateTime.now()) - const Duration(minutes: 1);
            return d <= Duration.zero ? const Duration(seconds: 5) : d;
          }();

    _logger.info(isRetry ? 'Retry scheduled in 30s' : 'Token refresh in ${duration.inMinutes}m ${duration.inSeconds % 60}s');

    _refreshTimer = Timer(duration, attemptRefresh);
  }

  /// Coalescing refresh: concurrent callers share the same in-flight future.
  Future<RefreshResult> attemptRefresh() {
    if (_refreshCompleter != null && !_refreshCompleter!.isCompleted) {
      return _refreshCompleter!.future;
    }
    final completer = Completer<RefreshResult>();
    _refreshCompleter = completer;
    _doRefresh().then(
      (result) {
        _refreshCompleter = null;
        completer.complete(result);
      },
      onError: (e, st) {
        _refreshCompleter = null;
        completer.complete(RefreshTransientFailure(cause: e));
      },
    );
    return completer.future;
  }

  Future<RefreshResult> _doRefresh() async {
    _logger.info('Attempting token refresh.');

    try {
      if (_oauthClient == null) {
        await onPermanentFailure();
        return const RefreshPermanentFailure();
      }

      _oauthClient = await _refreshOperation(_oauthClient!, _scopes).timeout(_refreshTimeout);
      // Both flags have to be re-supplied on every refresh: oauth2.Credentials
      // carries neither, so omitting them would quietly downgrade an offline
      // session to a 30-day one on its first refresh.
      final credentials = UserCredentials.fromOAuth2(
        _oauthClient!.credentials,
        isOfflineToken: _isOfflineSession,
        refreshTokenLifetime: _refreshTokenLifetime,
      );
      await _store.setCredentials(credentials);

      final wasFailedBefore = _previousRefreshFailed;
      _previousRefreshFailed = false;
      scheduleRefresh(credentials);

      // Before onRecovery: that one kicks off a userinfo round trip, and a
      // consumer waiting to re-dial with the new token should not queue
      // behind it.
      onTokenRefreshed();

      if (wasFailedBefore) onRecovery();

      _logger.info('Token refresh successful.');
      return RefreshSuccess(credentials);
    } on oauth2.ExpirationException {
      _logger.warning('Session expired, re-authentication required.');
      await onPermanentFailure();
      return const RefreshPermanentFailure();
    } on oauth2.AuthorizationException catch (e, st) {
      if (e.error == 'invalid_grant') {
        _logger.warning('Refresh token revoked or expired (invalid_grant).');
        await onPermanentFailure();
        return const RefreshPermanentFailure();
      }
      _logger.severe('Authorization error during refresh, retrying in 30s.', e, st);
      return await _handleTransientFailure(e);
    } on SocketException catch (e, st) {
      _logger.warning('Network error during refresh, retrying in 30s.', e, st);
      return await _handleTransientFailure(e);
    } on TimeoutException catch (e, st) {
      _logger.warning('Token refresh timed out, retrying in 30s.', e, st);
      return await _handleTransientFailure(e);
    }
  }

  Future<RefreshResult> _handleTransientFailure(Object cause) async {
    _previousRefreshFailed = true;
    final stored = await _store.getCredentials();
    if (stored == null || stored.isRefreshExpired) {
      _logger.warning('Refresh token locally expired during transient failure — ending session.');
      await onPermanentFailure();
      return const RefreshPermanentFailure();
    }
    scheduleRefresh(stored, isRetry: true);
    return RefreshTransientFailure(cause: cause);
  }

  /// Sends the Keycloak logout/revocation request to the server.
  /// Errors are swallowed — logout continues locally regardless.
  Future<void> revokeSession({required Uri logoutEndpoint, required String clientId, required String refreshToken, String? idToken}) async {
    if (_oauthClient == null) return;
    try {
      // `?idToken` omits the key when null rather than sending a null value:
      // a null in the map makes it a Map<String, String?>, which http rejects
      // when it casts the body to form fields. That throw lands in the catch
      // below, so a session would silently stop being revoked server-side.
      await _oauthClient!.post(logoutEndpoint, body: {'client_id': clientId, 'refresh_token': refreshToken, 'id_token_hint': ?idToken});
    } catch (_) {
      // Intentionally swallowed — caller handles fallback
    }
  }

  void dispose() {
    _refreshTimer?.cancel();
    _oauthClient?.close();
    _oauthClient = null;
  }
}
