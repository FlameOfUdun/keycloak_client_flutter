import 'dart:async';

import 'package:oauth2/oauth2.dart';
import 'package:web/web.dart' show window;

import '../models/client_config.dart';
import '../models/keycloak_exception.dart';
import '../models/platform_config.dart';
import '../interfaces/login_strategy.dart';
import '../models/pending_grant.dart';
import '../utilities/pkce.dart';
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
  final void Function(Uri)? _redirect;

  WebLoginStrategy() : _store = const SessionStoragePendingGrantStore(), _redirect = null;

  /// Test-only constructor — inject a fake [store] and a [redirect] that
  /// records the URL instead of navigating the tab.
  WebLoginStrategy.withDependencies({
    required IPendingGrantStore store,
    required void Function(Uri) redirect,
  }) : _store = store,
       _redirect = redirect;

  static void _defaultRedirect(Uri authUrl) {
    window.location.href = authUrl.toString();
  }

  @override
  Future<Client?> login({
    required WebConfig platformConfig,
    required ClientConfig clientConfig,
  }) async {
    final verifier = generateCodeVerifier();
    final state = generateState();

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
        authorizationEndpoint: clientConfig.authorizationEndpoint,
        tokenEndpoint: clientConfig.tokenEndpoint,
        redirectUri: redirect,
        scopes: clientConfig.scopes,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ttlMs: platformConfig.pendingGrantTTL.inMilliseconds,
      ),
    );

    // The injected redirect wins so a test can assert on the URL without the
    // tab navigating out from under it.
    (_redirect ?? platformConfig.launchAuthUrl ?? _defaultRedirect)(authUrl);

    // The tab is unloading; this future intentionally never completes.
    return Completer<Client?>().future;
  }

  @override
  Future<Client?> handleCallback(Uri callbackUri, {String? clientSecret}) async {
    _store.sweepExpired();

    final params = callbackUri.queryParameters;
    final state = params['state'];
    if (state == null) return null;

    if (_store.isExpired(state)) {
      _store.takeValid(state);
      throw const KeycloakTimeoutException('Web login timed out.');
    }

    // Consumed before the error check so a replayed callback cannot reuse the
    // grant, whatever the IdP said.
    final pending = _store.takeValid(state);
    if (pending == null) return null;

    final error = params['error'];
    if (error != null) {
      if (error == 'access_denied') return null; // declined at the consent screen
      throw KeycloakServerException(400, error);
    }

    final grant = AuthorizationCodeGrant(
      pending.clientId,
      pending.authorizationEndpoint,
      pending.tokenEndpoint,
      secret: clientSecret,
      codeVerifier: pending.codeVerifier,
    );

    // oauth2 requires getAuthorizationUrl to be called once before
    // handleAuthorizationResponse so the grant moves into the
    // "awaiting response" state — and passing `state` here is what arms its
    // own comparison against the callback's.
    grant.getAuthorizationUrl(
      pending.redirectUri,
      scopes: pending.scopes,
      state: state,
    );

    try {
      return await grant.handleAuthorizationResponse(params);
    } on AuthorizationException catch (e) {
      throw KeycloakServerException(400, e.error);
    } on FormatException catch (e) {
      throw KeycloakServerException(400, e.message);
    }
  }
}
