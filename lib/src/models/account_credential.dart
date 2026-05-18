import 'dart:convert';

/// One credential type configured (or supported) for the current user, as
/// returned by Keycloak's account REST API
/// (`/realms/{realm}/account/credentials`).
///
/// Sealed family — pattern match to read type-specific fields:
///
/// ```dart
/// switch (credential) {
///   case PasswordCredential():                   /* … */
///   case OtpCredential(:final instances):        /* … */
///   case WebAuthnCredential(:final instances):   /* … */
///   case UnknownCredential():                    /* … */
/// }
/// ```
sealed class AccountCredential {
  /// Credential type identifier, e.g. `password`, `otp`, `webauthn`.
  final String type;

  /// Higher-level grouping, e.g. `password`, `two-factor`, `passwordless`.
  final String category;

  /// Human-readable label, e.g. "Authenticator application".
  final String? displayName;

  const AccountCredential({
    required this.type,
    required this.category,
    this.displayName,
  });

  /// Number of user-configured instances of this credential type.
  int get instanceCount;

  /// Whether the user has at least one instance configured.
  bool get isConfigured => instanceCount > 0;

  /// Parses a single container from Keycloak's account credentials response.
  /// Unknown `type` values map to [UnknownCredential] so realm-specific or
  /// future credential providers don't break the client.
  factory AccountCredential.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    final category = (json['category'] as String?) ?? '';
    final displayName = json['displayName'] as String?;
    // Keycloak's account REST API returns instances under `userCredentialMetadatas`,
    // each wrapped in a metadata envelope with the credential under `.credential`.
    // Older/alternative shapes use `userCredentials` directly — accept both.
    final raw = (json['userCredentialMetadatas'] as List<dynamic>?) ??
        (json['userCredentials'] as List<dynamic>?) ??
        const [];
    final maps = raw.whereType<Map<String, dynamic>>().map((entry) {
      final inner = entry['credential'];
      return inner is Map<String, dynamic> ? inner : entry;
    }).toList(growable: false);

    return switch (type) {
      'password' => PasswordCredential(
        type: type,
        category: category,
        displayName: displayName,
        instances: maps.map(PasswordInstance.fromJson).toList(growable: false),
      ),
      'otp' => OtpCredential(
        type: type,
        category: category,
        displayName: displayName,
        instances: maps.map(OtpInstance.fromJson).toList(growable: false),
      ),
      'webauthn' || 'webauthn-passwordless' => WebAuthnCredential(
        type: type,
        category: category,
        displayName: displayName,
        instances: maps.map(WebAuthnInstance.fromJson).toList(growable: false),
      ),
      _ => UnknownCredential(
        type: type,
        category: category,
        displayName: displayName,
        instances: maps.map(UnknownInstance.fromJson).toList(growable: false),
      ),
    };
  }
}

final class PasswordCredential extends AccountCredential {
  final List<PasswordInstance> instances;
  const PasswordCredential({
    required super.type,
    required super.category,
    required this.instances,
    super.displayName,
  });
  @override
  int get instanceCount => instances.length;
}

final class OtpCredential extends AccountCredential {
  final List<OtpInstance> instances;
  const OtpCredential({
    required super.type,
    required super.category,
    required this.instances,
    super.displayName,
  });
  @override
  int get instanceCount => instances.length;
}

final class WebAuthnCredential extends AccountCredential {
  final List<WebAuthnInstance> instances;
  const WebAuthnCredential({
    required super.type,
    required super.category,
    required this.instances,
    super.displayName,
  });
  @override
  int get instanceCount => instances.length;
}

final class UnknownCredential extends AccountCredential {
  final List<UnknownInstance> instances;
  const UnknownCredential({
    required super.type,
    required super.category,
    required this.instances,
    super.displayName,
  });
  @override
  int get instanceCount => instances.length;
}

// ─── Instance models ─────────────────────────────────────────────────────────

enum OtpSubType { totp, hotp, unknown }

final class PasswordInstance {
  final String id;
  final String? userLabel;
  final DateTime? createdDate;

  const PasswordInstance({
    required this.id,
    this.userLabel,
    this.createdDate,
  });

  factory PasswordInstance.fromJson(Map<String, dynamic> json) =>
      PasswordInstance(
        id: (json['id'] as String?) ?? '',
        userLabel: json['userLabel'] as String?,
        createdDate: _parseEpochMs(json['createdDate']),
      );
}

final class OtpInstance {
  final String id;
  final String? userLabel;
  final DateTime? createdDate;
  final OtpSubType subType;
  final int? digits;
  final int? period;
  final String? algorithm;

  const OtpInstance({
    required this.id,
    this.userLabel,
    this.createdDate,
    this.subType = OtpSubType.unknown,
    this.digits,
    this.period,
    this.algorithm,
  });

  factory OtpInstance.fromJson(Map<String, dynamic> json) {
    final data = _decodeCredentialData(json['credentialData']);
    final subType = switch ((data?['subType'] as String?)?.toLowerCase()) {
      'totp' => OtpSubType.totp,
      'hotp' => OtpSubType.hotp,
      _ => OtpSubType.unknown,
    };
    return OtpInstance(
      id: (json['id'] as String?) ?? '',
      userLabel: json['userLabel'] as String?,
      createdDate: _parseEpochMs(json['createdDate']),
      subType: subType,
      digits: data?['digits'] as int?,
      period: data?['period'] as int?,
      algorithm: data?['algorithm'] as String?,
    );
  }
}

final class WebAuthnInstance {
  final String id;
  final String? userLabel;
  final DateTime? createdDate;
  final String? aaguid;

  const WebAuthnInstance({
    required this.id,
    this.userLabel,
    this.createdDate,
    this.aaguid,
  });

  factory WebAuthnInstance.fromJson(Map<String, dynamic> json) {
    final data = _decodeCredentialData(json['credentialData']);
    return WebAuthnInstance(
      id: (json['id'] as String?) ?? '',
      userLabel: json['userLabel'] as String?,
      createdDate: _parseEpochMs(json['createdDate']),
      aaguid: data?['aaguid'] as String?,
    );
  }
}

final class UnknownInstance {
  final String id;
  final String? userLabel;
  final DateTime? createdDate;
  final Map<String, dynamic>? credentialData;

  const UnknownInstance({
    required this.id,
    this.userLabel,
    this.createdDate,
    this.credentialData,
  });

  factory UnknownInstance.fromJson(Map<String, dynamic> json) =>
      UnknownInstance(
        id: (json['id'] as String?) ?? '',
        userLabel: json['userLabel'] as String?,
        createdDate: _parseEpochMs(json['createdDate']),
        credentialData: _decodeCredentialData(json['credentialData']),
      );
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

DateTime? _parseEpochMs(Object? value) {
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is String) {
    final parsed = int.tryParse(value);
    return parsed == null ? null : DateTime.fromMillisecondsSinceEpoch(parsed);
  }
  return null;
}

// Best-effort: Keycloak ships `credentialData` as a JSON-encoded string.
// A malformed value yields `null` rather than throwing — one bad instance
// must not break parsing of the whole list.
Map<String, dynamic>? _decodeCredentialData(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}
