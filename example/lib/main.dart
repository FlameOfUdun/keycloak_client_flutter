import 'package:flutter/material.dart';
import 'package:keycloak_client/keycloak_client.dart';

void main() {
  runApp(_Application());
}

final class _Application extends StatefulWidget {
  const _Application();

  @override
  State<_Application> createState() => _ApplicationState();
}

final class _ApplicationState extends State<_Application> {
  final client = KeycloakClient(
    baseUrl: 'https://keycloak.example.com/auth', // Keycloak server URL
    clientId: 'flutter-app', // Keycloak client ID
    realm: 'myrealm', // Keycloak realm
    redirectUri: 'myapp://auth', // Must match the redirect URI configured in Keycloak and AndroidManifest.xml/Info.plist
    scopes: ['openid', 'profile', 'email', 'offline_access'], // Optional scopes
  );

  @override
  void initState() {
    client.initialize();
    super.initState();
  }

  @override
  void dispose() {
    client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: StreamBuilder(
          stream: client.onAuthChange,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('Error: ${snapshot.error}'));
            }
            final state = snapshot.data!;
            if (state.isSignedIn) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    UserInfoView(client: client),
                    ElevatedButton(onPressed: client.logout, child: const Text('Logout')),
                  ],
                ),
              );
            }
            if (state.isUnknown) {
              return const Center(child: CircularProgressIndicator());
            }
            return Center(
              child: ElevatedButton(onPressed: client.login, child: const Text('Login')),
            );
          },
        ),
      ),
    );
  }
}

final class UserInfoView extends StatelessWidget {
  final KeycloakClient client;

  const UserInfoView({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: client.onUserChange,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }
        final user = snapshot.data;
        if (user == null) {
          return const Center(child: Text('No user information available'));
        }
        return Center(
          child: Text('User: ${user.username}'),
        );
      },
    );
  }
}
