import 'package:oauth2/oauth2.dart';

import '../models/client_config.dart';
import '../models/platform_config.dart';

/// Abstract login strategy. Each platform implements its own flow.
abstract interface class ILoginStrategy<TConfig extends PlatformConfig> {
  /// Performs the full Authorization Code + PKCE flow and returns
  /// a fully authorised [Client], or `null` if the user cancelled.
  Future<Client?> login({
    required TConfig platformConfig,
    required ClientConfig clientConfig,
  });
}

abstract interface class IMobileLoginStrategy implements ILoginStrategy<MobileConfig> {}

abstract interface class IDesktopLoginStrategy implements ILoginStrategy<DesktopConfig> {}

abstract interface class IWebLoginStrategy implements ILoginStrategy<WebConfig> {
  /// Resumes a redirect-based login flow using the query parameters in
  /// [callbackUri]. Returns the authorised [Client] when a pending grant
  /// for the callback's `state` was found, validated, and exchanged.
  /// Returns `null` when there is no matching pending grant (so callers
  /// can invoke this unconditionally on app startup).
  ///
  /// Throws `KeycloakTimeoutException` when a matching pending grant
  /// exists but has exceeded the store's TTL.
  Future<Client?> handleCallback(Uri callbackUri);
}
