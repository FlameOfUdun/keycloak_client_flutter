part of 'main.dart';

final class _HomeScreen extends StatelessWidget {
  final KeycloakClient client;
  const _HomeScreen({required this.client});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          const _ModeChip(),
          // The account console is a user's; a service account has none, and
          // manageAccount() throws UnsupportedError in that mode.
          if (!_serviceAccount)
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
              spacing: 12,
              children: [
                _UserInfoCard(client: client),
                _RolesCard(client: client),
                _TokenRotationCard(client: client),
                // getAccountCredentials() throws UnsupportedError for a
                // service account.
                if (_serviceAccount)
                  const _ServiceAccountNote()
                else
                  _CredentialsCard(client: client),
                const SizedBox(height: 12),
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
          margin: const EdgeInsets.fromLTRB(24, 24, 24, 0),
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

/// Shows [KeycloakClient.roles], re-read on every [KeycloakClient.onTokenRefreshed].
///
/// "Refresh now" forces a refresh, so a role granted or revoked in the admin
/// console shows up (or, for the required role, ends the session as
/// [AuthState.accessDenied]) without waiting for the token to expire.
final class _RolesCard extends StatefulWidget {
  final KeycloakClient client;
  const _RolesCard({required this.client});

  @override
  State<_RolesCard> createState() => _RolesCardState();
}

final class _RolesCardState extends State<_RolesCard> {
  StreamSubscription<void>? _sub;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.client.onTokenRefreshed.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refreshNow() async {
    // Captured up front: losing the required role ends the session, which
    // unmounts this card before refreshToken() throws.
    final messenger = ScaffoldMessenger.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    setState(() => _refreshing = true);
    try {
      await widget.client.refreshToken();
    } on KeycloakAccessDeniedException catch (e) {
      _showError(
        messenger,
        errorColor,
        'Access denied after refresh — missing roles: '
        '${_describeRoles(e.missing)}',
      );
    } on Exception catch (e) {
      _showError(messenger, errorColor, 'Refresh failed: $e');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final roles = widget.client.roles;
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Roles', style: theme.textTheme.titleMedium),
                IconButton(
                  tooltip: 'Refresh token now',
                  icon: _refreshing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 20),
                  onPressed: _refreshing ? null : _refreshNow,
                ),
              ],
            ),
            if (_requiredRealmRole != '')
              _RequiredRoleRow(
                role: _requiredRealmRole,
                held: roles?.hasRealmRole(_requiredRealmRole) ?? false,
              ),
            if (roles == null)
              const Text('No roles: there is no session.')
            else ...[
              Text('Realm', style: theme.textTheme.labelLarge),
              _RoleChips(roles: roles.realm),
              for (final MapEntry(key: clientId, value: clientRoles)
                  in roles.client.entries) ...[
                Text('Client "$clientId"', style: theme.textTheme.labelLarge),
                _RoleChips(roles: clientRoles),
              ],
              if (roles.client.isEmpty)
                Text('No client roles.', style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

final class _RequiredRoleRow extends StatelessWidget {
  final String role;
  final bool held;
  const _RequiredRoleRow({required this.role, required this.held});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        spacing: 8,
        children: [
          Icon(
            held ? Icons.check_circle : Icons.cancel,
            color: held ? Colors.green : Theme.of(context).colorScheme.error,
            size: 18,
          ),
          Text(
            'Required realm role "$role": ${held ? 'held' : 'missing'}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

final class _RoleChips extends StatelessWidget {
  final Set<String> roles;
  const _RoleChips({required this.roles});

  @override
  Widget build(BuildContext context) {
    if (roles.isEmpty) {
      return Text('None.', style: Theme.of(context).textTheme.bodySmall);
    }
    final sorted = roles.toList()..sort();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final role in sorted)
          Chip(visualDensity: VisualDensity.compact, label: Text(role)),
      ],
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

/// Stands in for [_CredentialsCard] in service-account mode.
final class _ServiceAccountNote extends StatelessWidget {
  const _ServiceAccountNote();

  @override
  Widget build(BuildContext context) {
    return const Card(
      margin: EdgeInsets.symmetric(horizontal: 24),
      child: ListTile(
        leading: Icon(Icons.info_outline),
        title: Text('Service account'),
        subtitle: Text(
          'No account console or authentication methods: '
          'manageAccount() and getAccountCredentials() are only available '
          'to users.',
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
