import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:keycloak_client/keycloak_client.dart';

part 'home.dart';

// Supplied with --dart-define so this file can be run against a real server
// without editing it:
//
//   flutter run -d windows \
//     --dart-define=KC_BASE_URL=http://localhost:8080 \
//     --dart-define=KC_REALM=winche-demo \
//     --dart-define=KC_CLIENT_ID=flutter-app \
//     --dart-define=KC_DESKTOP_REDIRECT=http://localhost:8765/callback
//
// Optional:
//
//   --dart-define=KC_REQUIRED_REALM_ROLE=staff
//       Admit only principals holding this realm role. Others are turned away
//       at login (KeycloakAccessDeniedException) or, for a restored or
//       refreshed session, land on the access-denied screen.
//   --dart-define=KC_SERVICE_ACCOUNT=true
//   --dart-define=KC_CLIENT_SECRET=backend-sa-secret
//       Sign in as the client's own service account (client-credentials
//       grant, no browser). KC_CLIENT_ID must then name a confidential client
//       with service accounts enabled. KC_CLIENT_SECRET is also passed to a
//       confidential client in browser-login mode.
//
// See example/README.md for a local Keycloak with a realm set up for all of
// these.
const _baseUrl = String.fromEnvironment(
  'KC_BASE_URL',
  defaultValue: 'your-keycloak-server',
);
const _realm = String.fromEnvironment('KC_REALM', defaultValue: 'your-realm');
const _clientId = String.fromEnvironment(
  'KC_CLIENT_ID',
  defaultValue: 'your-client-id',
);
const _clientSecret = String.fromEnvironment('KC_CLIENT_SECRET');
const _serviceAccount = bool.fromEnvironment('KC_SERVICE_ACCOUNT');
const _requiredRealmRole = String.fromEnvironment('KC_REQUIRED_REALM_ROLE');

/// Where Keycloak sends the browser back to.
///
/// Desktop defaults to a hosted page that bounces to the loopback listener,
/// because Keycloak rejects some loopback redirect URIs. Point it straight at
/// the loopback when your realm allows it, as the local test realm does.
const _desktopRedirect = String.fromEnvironment(
  'KC_DESKTOP_REDIRECT',
  defaultValue: 'https://winchetechnologies.co.uk/tools/oauth_redirect',
);
const _webRedirect = String.fromEnvironment(
  'KC_WEB_REDIRECT',
  defaultValue: 'https://winchetechnologies.co.uk/tools/oauth_redirect',
);

/// The KeycloakClient constructor rejects a service account without a secret;
/// checked up front so the app can say so instead of failing to start.
const _missingSecret = _serviceAccount && _clientSecret == '';

final client = KeycloakClient(
  clientConfig: ClientConfig(
    baseUrl: _baseUrl,
    realm: _realm,
    clientId: _clientId,
    clientSecret: _clientSecret == '' ? null : _clientSecret,
    grantType: _serviceAccount
        ? GrantType.clientCredentials
        : GrantType.authorizationCode,
    requiredRealmRoles: {if (_requiredRealmRole != '') _requiredRealmRole},
    refreshTimeout: const Duration(seconds: 3),
  ),
  desktopConfig: const DesktopConfig(redirectUri: _desktopRedirect),
  webConfig: const WebConfig(redirectUri: _webRedirect),
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_missingSecret) {
    runApp(const _ConfigErrorApp());
    return;
  }

  // Web only: resolve any in-progress OAuth callback before the app renders.
  // A service account has no redirect flow (handleWebCallback would throw).
  if (kIsWeb && !_serviceAccount) {
    try {
      final resumed = await client.handleWebCallback(Uri.base);
      if (resumed) {
        debugPrint('OAuth callback completed, session restored.');
      }
    } on Exception catch (e) {
      debugPrint('OAuth callback failed: $e');
    }
  }

  runApp(const _Application());
}

final class _ConfigErrorApp extends StatelessWidget {
  const _ConfigErrorApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Keycloak Example',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const Scaffold(
        body: Center(
          child: _ErrorTile(
            message:
                'KC_SERVICE_ACCOUNT=true needs the client secret: pass '
                '--dart-define=KC_CLIENT_SECRET=...',
          ),
        ),
      ),
    );
  }
}

final class _Application extends StatefulWidget {
  const _Application();

  @override
  State<_Application> createState() => _ApplicationState();
}

final class _ApplicationState extends State<_Application> {
  @override
  void initState() {
    super.initState();
    client.initialize();
  }

  @override
  void dispose() {
    client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Keycloak Example',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: _AuthGate(client: client),
    );
  }
}

final class _AuthGate extends StatelessWidget {
  final KeycloakClient client;
  const _AuthGate({required this.client});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: client.onAuthChange,
      builder: (context, snapshot) {
        final state = snapshot.data ?? AuthState.unknown;

        return switch (state) {
          AuthState.unknown => const _LoadingScreen(),
          AuthState.signedIn => _HomeScreen(client: client),
          AuthState.signedOut => _LoginScreen(client: client),
          AuthState.sessionExpired => _SessionExpiredScreen(client: client),
          AuthState.accessDenied => _AccessDeniedScreen(client: client),
        };
      },
    );
  }
}

final class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

/// Shows which way this build signs in, so a screenshot or a tester can tell
/// the two modes apart at a glance.
final class _ModeChip extends StatelessWidget {
  const _ModeChip();

  @override
  Widget build(BuildContext context) {
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(
        _serviceAccount ? Icons.smart_toy_outlined : Icons.open_in_browser,
        size: 18,
      ),
      label: Text(_serviceAccount ? 'Service account' : 'Browser login'),
    );
  }
}

/// "realm: staff; my-client: editor" — for the roles a
/// [KeycloakAccessDeniedException] reports as missing.
String _describeRoles(KeycloakRoles roles) {
  return [
    if (roles.realm.isNotEmpty) 'realm: ${roles.realm.join(', ')}',
    for (final MapEntry(:key, :value) in roles.client.entries)
      if (value.isNotEmpty) '$key: ${value.join(', ')}',
  ].join('; ');
}

/// Shows [message] as an error snackbar on [messenger].
///
/// Takes the messenger rather than a context because the caller has often
/// been unmounted by the time it has something to report: a denied login
/// or refresh changes the auth state, which swaps the screen it lived on.
void _showError(ScaffoldMessengerState messenger, Color color, String message) {
  messenger.showSnackBar(
    SnackBar(content: Text(message), backgroundColor: color),
  );
}

/// A sign-in button that reports what it is doing.
///
/// Login takes the user out to a browser and back, which can take a while and
/// gives the app no progress to show. Without feedback the window just sits
/// there looking idle, so people tap again — and a failure surfaces as an
/// unhandled exception rather than something readable.
final class _SignInButton extends StatefulWidget {
  final KeycloakClient client;
  final String label;
  const _SignInButton({required this.client, required this.label});

  @override
  State<_SignInButton> createState() => _SignInButtonState();
}

final class _SignInButtonState extends State<_SignInButton> {
  bool _busy = false;

  Future<void> _signIn() async {
    // Captured up front: a denied login moves the app to signedOut, which may
    // replace the screen this button is on before the error arrives.
    final messenger = ScaffoldMessenger.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    setState(() => _busy = true);
    try {
      await widget.client.login();
    } on KeycloakAccessDeniedException catch (e) {
      _showError(
        messenger,
        errorColor,
        'Access denied — missing roles: ${_describeRoles(e.missing)}',
      );
    } on Exception catch (e) {
      _showError(messenger, errorColor, 'Sign-in failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 12,
      children: [
        FilledButton.icon(
          onPressed: _busy ? null : _signIn,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(_serviceAccount ? Icons.smart_toy_outlined : Icons.login),
          label: Text(widget.label),
        ),
        if (_busy)
          Text(
            _serviceAccount
                ? 'Requesting a token…'
                : 'Waiting for you to finish in the browser…',
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }
}

/// Mentions the required role, when one is configured, under a sign-in
/// prompt.
final class _RequiredRoleHint extends StatelessWidget {
  const _RequiredRoleHint();

  @override
  Widget build(BuildContext context) {
    if (_requiredRealmRole == '') return const SizedBox.shrink();
    return Text(
      'Requires realm role "$_requiredRealmRole"',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}

final class _LoginScreen extends StatelessWidget {
  final KeycloakClient client;
  const _LoginScreen({required this.client});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            const Icon(Icons.lock_outline, size: 64, color: Colors.teal),
            Text(
              'Sign in to continue',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const _ModeChip(),
            _SignInButton(
              client: client,
              label: _serviceAccount
                  ? 'Sign in as service account'
                  : 'Sign in with Keycloak',
            ),
            const _RequiredRoleHint(),
          ],
        ),
      ),
    );
  }
}

final class _SessionExpiredScreen extends StatelessWidget {
  final KeycloakClient client;
  const _SessionExpiredScreen({required this.client});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            const Icon(
              Icons.timer_off_outlined,
              size: 64,
              color: Colors.orange,
            ),
            Text(
              'Your session has expired',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Text('Please sign in again to continue.'),
            _SignInButton(client: client, label: 'Sign in again'),
          ],
        ),
      ),
    );
  }
}

/// [AuthState.accessDenied]: a restored or refreshed session turned out to
/// lack a required role, so the client ended it.
///
/// A login without the role never gets here — [KeycloakClient.login] throws
/// instead and the app stays signed out; [_SignInButton] reports that.
final class _AccessDeniedScreen extends StatelessWidget {
  final KeycloakClient client;
  const _AccessDeniedScreen({required this.client});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 16,
            children: [
              Icon(
                Icons.gpp_bad_outlined,
                size: 64,
                color: Theme.of(context).colorScheme.error,
              ),
              Text(
                'Access denied',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(
                _requiredRealmRole == ''
                    ? 'This account no longer holds a role this app requires, '
                          'so you have been signed out.'
                    : 'This account does not hold the realm role '
                          '"$_requiredRealmRole" this app requires, so you '
                          'have been signed out.',
                textAlign: TextAlign.center,
              ),
              const Text(
                'Sign in with an account that has it, or ask an administrator '
                'to grant it.',
                textAlign: TextAlign.center,
              ),
              _SignInButton(
                client: client,
                label: _serviceAccount
                    ? 'Sign in as service account again'
                    : 'Sign in again',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
