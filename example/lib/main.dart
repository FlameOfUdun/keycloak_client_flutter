import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:keycloak_client/keycloak_client.dart';

final client = KeycloakClient(
  config: ClientConfig(
    baseUrl: 'your-keycloak-server',
    realm: 'your-realm',
    clientId: 'your-client-id',
  ),
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
            Text('Sign in to continue', style: Theme.of(context).textTheme.titleLarge),
            FilledButton.icon(onPressed: client.login, icon: const Icon(Icons.login), label: const Text('Sign in with Keycloak')),
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
            const Icon(Icons.timer_off_outlined, size: 64, color: Colors.orange),
            Text('Your session has expired', style: Theme.of(context).textTheme.titleLarge),
            const Text('Please sign in again to continue.'),
            FilledButton.icon(onPressed: client.login, icon: const Icon(Icons.login), label: const Text('Sign in again')),
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
        actions: [IconButton(tooltip: 'Sign out', icon: const Icon(Icons.logout), onPressed: client.logout)],
      ),
      body: Center(child: _UserInfoCard(client: client)),
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
                CircleAvatar(radius: 32, child: Text((user.username ?? user.email ?? '?')[0].toUpperCase(), style: const TextStyle(fontSize: 28))),
                if (user.username != null) Text(user.username!, style: Theme.of(context).textTheme.titleMedium),
                if (user.email != null) Text(user.email!, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey)),
                const Divider(),
                _InfoRow(label: 'ID', value: user.id),
                if (user.givenName != null) _InfoRow(label: 'First name', value: user.givenName!),
                if (user.familyName != null) _InfoRow(label: 'Last name', value: user.familyName!),
              ],
            ),
          ),
        );
      },
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
