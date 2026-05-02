sealed class PlatformConfig {
  /// The redirect URI that the authentication provider will use to return to
  /// the app after the user completes the login process. This should be a URI
  /// that your app can handle, such as a custom scheme for mobile or a specific
  /// URL for desktop and web. The default values are set to common patterns, but
  /// you should customize this to match your app's configuration and ensure it is
  /// registered correctly with your authentication provider.
  /// 
  /// For mobile, the default is `myapp://auth`, which is a common custom scheme pattern. 
  /// 
  /// For desktop and web, the default is `https://winchetechnologies.co.uk/tools/oauth_redirect`, 
  /// which is a placeholder URL that you should replace with your own registered redirect URI.
  /// Since latest versions of keycloak prohibits using localhost redirect URIs, you can register 
  /// the default desktop redirect URI with your Keycloak server and use it as is, 
  /// or customize it to match your app's branding and domain.
  final String redirectUri;

  const PlatformConfig({
    required this.redirectUri,
  });
}

/// Placeholder for future mobile-only login settings.
final class MobileConfig extends PlatformConfig {
  /// The maximum time to wait for the deep link callback after launching the
  /// browser for login before giving up and throwing a timeout error. This is
  /// important to prevent the app from waiting indefinitely if the user abandons
  /// the login process after the browser is launched.
  /// 
  /// Default is 5 minutes, which should be more than enough for any user to 
  /// complete the login process, even if they need to reset their password or 
  /// perform multi-factor authentication. You can adjust this timeout based 
  /// on your user base and expected login flow complexity, but it's generally 
  /// not recommended to set it too low to avoid cutting off users who may need more time.
  final Duration deepLinkTimeout;

  const MobileConfig({
    super.redirectUri = 'myapp://auth',
    this.deepLinkTimeout = const Duration(minutes: 5),
  });
}

final class DesktopConfig extends PlatformConfig {
  /// The local callback URL that the desktop listener expects after the
  /// browser flow returns to the app.
  /// 
  /// If no loopback URI is provided, the redirect URI will be used.
  /// 
  /// You can use this to specify a different URI for the loopback listener 
  /// if needed, but it should generally be a localhost URL that the app can 
  /// listen on, such as the default `http://localhost:8765/callback`.
  final String? loopbackUri;

  /// The HTML page shown to the user after a successful login. This should
  /// include instructions to return to the app, since the browser is now
  /// detached from the app and won't automatically close.
  ///
  /// By default, this is a simple page with a success message, but you can
  /// customize it to match your app's branding and provide more specific
  /// instructions if needed.
  final String? successPageHtml;

  /// The maximum time to wait for the browser to redirect back to the app
  /// before giving up and throwing a timeout error. This is important to
  /// prevent the app from waiting indefinitely if the user abandons the login
  /// process after the browser is launched.
  ///
  /// Default is 5 minutes, which should be more than enough for any user to
  /// complete the login process, even if they need to reset their password or
  /// perform multi-factor authentication. You can adjust this timeout based on
  /// your user base and expected login flow complexity, but it's generally
  /// not recommended to set it too low to avoid cutting off users who may need
  /// more time.
  final Duration loopbackTimeout;

  const DesktopConfig({
    super.redirectUri = 'https://winchetechnologies.co.uk/tools/oauth_redirect',
    this.loopbackUri = 'http://localhost:8765/callback',
    this.successPageHtml,
    this.loopbackTimeout = const Duration(minutes: 5),
  });
}

/// Placeholder for future web-only login settings.
final class WebConfig extends PlatformConfig {
  /// The TTL for pending grants stored during the redirect-based login flow.
  ///
  /// This should be long enough to allow users to complete the login process,
  /// including any multi-factor authentication steps, but not so long that
  /// stale grants accumulate in the store. A common choice is around 10-15
  /// minutes, but you can adjust this based on your user base and expected login
  /// flow complexity.
  final Duration pendingGrantTTL;

  /// Optional callback to launch the authorization URL in a new browser tab or
  /// window. This is required for web login since `url_launcher` does not work
  /// on web platforms. The callback should handle opening the URL and can be
  /// used to integrate with your app's routing or state management if needed.
  final void Function(Uri authUrl)? launchAuthUrl;
  
  const WebConfig({
    super.redirectUri = 'https://winchetechnologies.co.uk/tools/oauth_redirect',
    this.pendingGrantTTL = const Duration(minutes: 15), this.launchAuthUrl});
}
