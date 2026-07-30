import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:keycloak_client/keycloak_client.dart';

// Supplied with --dart-define so this file can be run against a real server
// without editing it:
//
//   flutter run -d windows \
//     --dart-define=KC_BASE_URL=http://localhost:8080 \
//     --dart-define=KC_REALM=winche-test \
//     --dart-define=KC_CLIENT_ID=flutter-app \
//     --dart-define=KC_DESKTOP_REDIRECT=http://localhost:8765/callback
const _baseUrl = String.fromEnvironment(
  'KC_BASE_URL',
  defaultValue: 'your-keycloak-server',
);
const _realm = String.fromEnvironment('KC_REALM', defaultValue: 'your-realm');
const _clientId = String.fromEnvironment(
  'KC_CLIENT_ID',
  defaultValue: 'your-client-id',
);

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

final client = KeycloakClient(
  clientConfig: ClientConfig(
    baseUrl: _baseUrl,
    realm: _realm,
    clientId: _clientId,
    refreshTimeout: const Duration(seconds: 3),
  ),
  desktopConfig: const DesktopConfig(redirectUri: _desktopRedirect),
  webConfig: const WebConfig(redirectUri: _webRedirect),
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Web only: resolve any in-progress OAuth callback before the app renders.
  if (kIsWeb) {
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
    setState(() => _busy = true);
    try {
      await widget.client.login();
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sign-in failed: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
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
              : const Icon(Icons.login),
          label: Text(widget.label),
        ),
        if (_busy)
          Text(
            'Waiting for you to finish in the browser…',
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
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
            _SignInButton(client: client, label: 'Sign in with Keycloak'),
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

final class _HomeScreen extends StatelessWidget {
  final KeycloakClient client;
  const _HomeScreen({required this.client});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          IconButton(
            tooltip: 'Manage account',
            icon: const Icon(Icons.manage_accounts),
            onPressed: client.manageAccount,
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: client.logout,
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _UserInfoCard(client: client),
                _TokenRotationCard(client: client),
                _CredentialsCard(client: client),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _UserInfoCard extends StatelessWidget {
  final KeycloakClient client;
  const _UserInfoCard({required this.client});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UserInfo?>(
      stream: client.onUserChange,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const CircularProgressIndicator();
        }

        if (snapshot.hasError) {
          return _ErrorTile(message: '${snapshot.error}');
        }

        final user = snapshot.data;
        if (user == null) {
          return const Text('No user information available.');
        }

        return Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                CircleAvatar(
                  radius: 32,
                  child: Text(
                    (user.username ?? user.email ?? '?')[0].toUpperCase(),
                    style: const TextStyle(fontSize: 28),
                  ),
                ),
                if (user.username != null)
                  Text(
                    user.username!,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                if (user.email != null)
                  Text(
                    user.email!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                  ),
                const Divider(),
                _InfoRow(label: 'ID', value: user.id),
                if (user.givenName != null)
                  _InfoRow(label: 'First name', value: user.givenName!),
                if (user.familyName != null)
                  _InfoRow(label: 'Last name', value: user.familyName!),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Watches [KeycloakClient.onTokenRefreshed].
///
/// A connection authenticated once at dial time would use this to re-dial
/// before the token it holds expires; here it just counts, so a refresh is
/// visible without waiting for something to break.
final class _TokenRotationCard extends StatefulWidget {
  final KeycloakClient client;
  const _TokenRotationCard({required this.client});

  @override
  State<_TokenRotationCard> createState() => _TokenRotationCardState();
}

final class _TokenRotationCardState extends State<_TokenRotationCard> {
  StreamSubscription<void>? _sub;
  int _rotations = 0;
  DateTime? _lastAt;
  String? _tokenTail;

  @override
  void initState() {
    super.initState();
    _sub = widget.client.onTokenRefreshed.listen((_) async {
      final token = await widget.client.getAuthToken();
      if (!mounted) return;
      setState(() {
        _rotations++;
        _lastAt = DateTime.now();
        _tokenTail = token == null
            ? null
            : '…${token.substring(token.length - 8)}';
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Text(
              'Token rotation',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            _InfoRow(label: 'Refreshes seen', value: '$_rotations'),
            _InfoRow(
              label: 'Last at',
              value: _lastAt == null
                  ? 'not yet'
                  : TimeOfDay.fromDateTime(_lastAt!).format(context),
            ),
            _InfoRow(label: 'Access token', value: _tokenTail ?? '—'),
          ],
        ),
      ),
    );
  }
}

final class _CredentialsCard extends StatefulWidget {
  final KeycloakClient client;
  const _CredentialsCard({required this.client});

  @override
  State<_CredentialsCard> createState() => _CredentialsCardState();
}

final class _CredentialsCardState extends State<_CredentialsCard> {
  late Future<List<AccountCredential>> _future =
      widget.client.getAccountCredentials();

  void _refresh() {
    setState(() {
      _future = widget.client.getAccountCredentials();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Authentication methods',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: _refresh,
                ),
              ],
            ),
            FutureBuilder<List<AccountCredential>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError) {
                  return _ErrorTile(message: '${snapshot.error}');
                }
                final credentials = snapshot.data ?? const [];
                if (credentials.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('No credentials configured.'),
                  );
                }
                return Column(
                  children: credentials.map(_credentialTile).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _credentialTile(AccountCredential credential) {
    // Pattern match on the sealed family for type-specific rendering.
    final (IconData icon, String subtitle) = switch (credential) {
      PasswordCredential() => (
        Icons.password,
        credential.isConfigured ? 'Configured' : 'Not configured',
      ),
      OtpCredential(:final instances) => (
        Icons.security,
        instances.isEmpty
            ? 'Not configured'
            : instances
                  .map((i) => '${i.userLabel ?? 'OTP'} · ${i.subType.name}')
                  .join(', '),
      ),
      WebAuthnCredential(:final instances) => (
        Icons.fingerprint,
        instances.isEmpty
            ? 'Not configured'
            : instances.map((i) => i.userLabel ?? 'Authenticator').join(', '),
      ),
      UnknownCredential() => (
        Icons.help_outline,
        '${credential.instanceCount} configured',
      ),
    };

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(credential.displayName ?? credential.type),
      subtitle: Text(subtitle),
      trailing: credential.isConfigured
          ? const Icon(Icons.check_circle, color: Colors.green, size: 18)
          : const Icon(Icons.radio_button_unchecked, size: 18),
    );
  }
}

final class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        Text(value),
      ],
    );
  }
}

final class _ErrorTile extends StatelessWidget {
  final String message;
  const _ErrorTile({required this.message});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.error_outline, color: Colors.red),
      title: const Text('Something went wrong'),
      subtitle: Text(message),
    );
  }
}
