import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:oauth2/oauth2.dart' as oauth2;

import '../enums/refresh_result.dart';
import '../interfaces/auth_credentials_store.dart';
import '../models/user_credentials.dart';

/// Signature for the OAuth2 token refresh operation.
/// Injectable so tests can simulate server responses without HTTP.
typedef RefreshOperation = Future<oauth2.Client> Function(oauth2.Client current, List<String> scopes);

/// Applies [timeout] to [pending], a future producing a new OAuth2 client.
///
/// A timeout abandons [pending] but not the request behind it: if that later
/// succeeds, the client it produces is closed, so its connection is not
/// leaked. [keep] is never closed — the auth-code refresh returns the very
/// client it was given, which is still in use.
Future<oauth2.Client> closeIfLate(Future<oauth2.Client> pending, Duration timeout, {oauth2.Client? keep}) =>
    pending.timeout(
      timeout,
      onTimeout: () {
        pending.then((client) {
          if (!identical(client, keep)) client.close();
        }, onError: (_) {}).ignore();
        throw TimeoutException('Timed out after $timeout.', timeout);
      },
    );

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
  final Set<String> _permanentAuthErrors;

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
    Set<String>? permanentAuthErrors,
    RefreshOperation? refreshOperation,
  }) : _store = store,
       _scopes = scopes,
       _logger = logger,
       _refreshTimeout = refreshTimeout,
       _refreshTokenLifetime = refreshTokenLifetime,
       _isOfflineSession = isOfflineSession,
       _permanentAuthErrors = permanentAuthErrors ?? const {'invalid_grant'},
       _refreshOperation = refreshOperation ?? ((client, scopes) => client.refreshCredentials(scopes));

  /// Exposes the active OAuth2 client for direct HTTP calls (userinfo, logout).
  oauth2.Client? get oauthClient => _oauthClient;

  /// Sets the active OAuth2 client. Called after login or on init with stored credentials.
  ///
  /// Closes the client it replaces (routine for a service account: restore,
  /// then login). A refresh still running on the old client is superseded and
  /// discards its result.
  void setClient(oauth2.Client client) {
    final previous = _oauthClient;
    _oauthClient = client;
    if (previous != null && !identical(previous, client)) previous.close();
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

    final previous = _oauthClient;
    if (previous == null) {
      await onPermanentFailure();
      return const RefreshPermanentFailure();
    }

    try {
      final next = await closeIfLate(_refreshOperation(previous, _scopes), _refreshTimeout, keep: previous);
      if (_superseded(previous)) {
        // The identical() guard matters because the auth-code refresh returns
        // the same instance it was given.
        if (!identical(next, previous)) next.close();
        return _discarded();
      }
      // Closed only now that it has actually been replaced, so a refresh that
      // fails or is dropped never closes a client that is still in use.
      if (!identical(next, previous)) previous.close();
      _oauthClient = next;
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
      if (_superseded(previous)) return _discarded();
      _logger.warning('Session expired, re-authentication required.');
      await onPermanentFailure();
      return const RefreshPermanentFailure();
    } on oauth2.AuthorizationException catch (e, st) {
      if (_superseded(previous)) return _discarded();
      // invalid_grant: the refresh token is revoked or expired. A service
      // account also lists invalid_client / unauthorized_client: its secret
      // was rotated or the client reconfigured, and no retry can fix that.
      if (_permanentAuthErrors.contains(e.error)) {
        _logger.warning('Refresh rejected permanently (${e.error}).');
        await onPermanentFailure();
        return const RefreshPermanentFailure();
      }
      _logger.severe('Authorization error during refresh, retrying in 30s.', e, st);
      return await _handleTransientFailure(e);
    } on SocketException catch (e, st) {
      if (_superseded(previous)) return _discarded();
      _logger.warning('Network error during refresh, retrying in 30s.', e, st);
      return await _handleTransientFailure(e);
    } on http.ClientException catch (e, st) {
      if (_superseded(previous)) return _discarded();
      _logger.warning('Network error during refresh, retrying in 30s.', e, st);
      return await _handleTransientFailure(e);
    } on FormatException catch (e, st) {
      if (_superseded(previous)) return _discarded();
      // oauth2 reports a non-JSON token response, such as a proxy's 5xx page,
      // as a FormatException: a server hiccup, not a verdict on the session.
      _logger.warning('Malformed token response during refresh, retrying in 30s.', e, st);
      return await _handleTransientFailure(e);
    } on TimeoutException catch (e, st) {
      if (_superseded(previous)) return _discarded();
      _logger.warning('Token refresh timed out, retrying in 30s.', e, st);
      return await _handleTransientFailure(e);
    }
  }

  /// Whether the session this refresh started from has since been ended
  /// (invalidate) or replaced (setClient) while the refresh was in flight.
  ///
  /// Every outcome checks this first. Ending a session closes the client's
  /// transport, so the refresh typically fails with a ClientException, and a
  /// failure that belongs to a session already over must not end it a second
  /// time: that would flip an explicit logout's signedOut to sessionExpired.
  bool _superseded(oauth2.Client previous) => !identical(_oauthClient, previous);

  /// The outcome of a superseded refresh: no store write, no retry, and no
  /// onPermanentFailure, since whoever ended the session already handled it.
  RefreshResult _discarded() {
    _logger.info('Session ended during refresh; discarding the result.');
    return const RefreshPermanentFailure();
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
      await _oauthClient!
          .post(logoutEndpoint, body: {'client_id': clientId, 'refresh_token': refreshToken, 'id_token_hint': ?idToken})
          .timeout(_refreshTimeout);
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
