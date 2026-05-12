import 'dart:async';
import 'dart:math';

import 'package:oauth2/oauth2.dart';
import 'package:web/web.dart' show window;

import '../models/client_config.dart';
import '../models/keycloak_exception.dart';
import '../models/platform_config.dart';
import '../interfaces/login_strategy.dart';
import '../models/pending_grant.dart';
import '../utilities/session_storage_pending_grant_store.dart';
import '../interfaces/pending_grant_store.dart';

/// Web login via same-tab redirect flow.
///
/// On `login()`, the strategy persists a [PendingGrant] to the
/// [IPendingGrantStore] and triggers a navigation to the authorisation
/// URL. The returned future never completes — the tab is being unloaded.
///
/// The consumer must call `KeycloakClient.handleWebCallback` from their
/// app's startup with `Uri.base`. That call routes to [handleCallback],
/// which rebuilds a fresh [AuthorizationCodeGrant] from the persisted
/// `codeVerifier` and exchanges the code for a [Client].
final class WebLoginStrategy implements IWebLoginStrategy {
  final IPendingGrantStore _store;

  WebLoginStrategy() : _store = const SessionStoragePendingGrantStore();

  /// Test-only constructor — inject a fake [store] and a [redirect] that
  /// records the URL instead of navigating the tab.
  WebLoginStrategy.withDependencies({
    required IPendingGrantStore store,
    required void Function(Uri) redirect,
  }) : _store = store;

  static void _defaultRedirect(Uri authUrl) {
    window.location.href = authUrl.toString();
  }

  @override
  Future<Client?> login({
    required WebConfig platformConfig,
    required ClientConfig clientConfig,
  }) async {
    final verifier = _generateCodeVerifier();
    final state = _generateState();

    final grant = AuthorizationCodeGrant(
      clientConfig.clientId,
      clientConfig.authorizationEndpoint,
      clientConfig.tokenEndpoint,
      secret: clientConfig.clientSecret,
      codeVerifier: verifier,
    );

    final redirect = Uri.parse(platformConfig.redirectUri);
    final authUrl = grant.getAuthorizationUrl(
      redirect,
      scopes: clientConfig.scopes,
      state: state,
    );

    _store.put(
      PendingGrant(
        state: state,
        codeVerifier: verifier,
        clientId: clientConfig.clientId,
        clientSecret: clientConfig.clientSecret,
        authorizationEndpoint: clientConfig.authorizationEndpoint,
        tokenEndpoint: clientConfig.tokenEndpoint,
        redirectUri: redirect,
        scopes: clientConfig.scopes,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    (platformConfig.launchAuthUrl ?? _defaultRedirect)(authUrl);

    // The tab is unloading; this future intentionally never completes.
    return Completer<Client?>().future;
  }

  @override
  Future<Client?> handleCallback(Uri callbackUri) async {
    _store.sweepExpired();

    final params = callbackUri.queryParameters;
    final state = params['state'];
    if (state == null) return null;

    if (_store.isExpired(state)) {
      _store.takeValid(state);
      throw const KeycloakTimeoutException('Web login timed out.');
    }

    final pending = _store.takeValid(state);
    if (pending == null) return null;

    if (params.containsKey('error')) return null;

    final grant = AuthorizationCodeGrant(
      pending.clientId,
      pending.authorizationEndpoint,
      pending.tokenEndpoint,
      secret: pending.clientSecret,
      codeVerifier: pending.codeVerifier,
    );

    // oauth2 requires getAuthorizationUrl to be called once before
    // handleAuthorizationResponse so the grant moves into the
    // "awaiting response" state.
    grant.getAuthorizationUrl(
      pending.redirectUri,
      scopes: pending.scopes,
      state: state,
    );

    try {
      return await grant.handleAuthorizationResponse(params);
    } on AuthorizationException catch (e) {
      throw KeycloakServerException(400, e.error);
    }
  }

  String _generateState() {
    final rng = Random.secure();
    return List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  String _generateCodeVerifier() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rng = Random.secure();
    return List.generate(64, (_) => chars[rng.nextInt(chars.length)]).join();
  }
}
