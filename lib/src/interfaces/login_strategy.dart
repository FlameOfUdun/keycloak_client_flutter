import 'package:oauth2/oauth2.dart';

import '../models/client_config.dart';
import '../models/platform_config.dart';

/// Abstract login strategy. Each platform implements its own flow.
abstract interface class ILoginStrategy<TConfig extends PlatformConfig> {
  /// Performs the full Authorization Code + PKCE flow and returns
  /// a fully authorised [Client], or `null` if the user cancelled.
  ///
  /// "Cancelled" means the IdP returned `access_denied` — the user declined at
  /// the consent screen. Every other `error` code is a failure and throws
  /// `KeycloakServerException`, because silently reporting a misconfigured
  /// client or an invalid scope as a cancellation leaves the caller with
  /// nothing to show and nothing to log.
  Future<Client?> login({
    required TConfig platformConfig,
    required ClientConfig clientConfig,
  });
}

abstract interface class IMobileLoginStrategy
    implements ILoginStrategy<MobileConfig> {}

abstract interface class IDesktopLoginStrategy
    implements ILoginStrategy<DesktopConfig> {}

abstract interface class IWebLoginStrategy
    implements ILoginStrategy<WebConfig> {
  /// Resumes a redirect-based login flow using the query parameters in
  /// [callbackUri]. Returns the authorised [Client] when a pending grant
  /// for the callback's `state` was found, validated, and exchanged.
  /// Returns `null` when there is no matching pending grant (so callers
  /// can invoke this unconditionally on app startup), and also when the user
  /// declined at the consent screen.
  ///
  /// [clientSecret] comes from the live [ClientConfig] rather than the
  /// persisted grant: the grant sits in browser storage, where a secret would
  /// be readable by any script on the origin. Normally null — a browser client
  /// should be a public one.
  ///
  /// Throws `KeycloakTimeoutException` when a matching pending grant exists but
  /// has exceeded its TTL, and `KeycloakServerException` when the IdP reported
  /// an error other than `access_denied`.
  Future<Client?> handleCallback(Uri callbackUri, {String? clientSecret});
}
