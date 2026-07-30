import 'package:web/web.dart' show window;

import '../models/pending_grant.dart';
import '../interfaces/pending_grant_store.dart';

const _kPendingGrantPrefix = 'keycloak_client.pending.';

/// Production [IPendingGrantStore] backed by `window.sessionStorage`.
///
/// SessionStorage survives the full-page OAuth redirect and dies with the
/// tab — exactly the lifetime we want for a CSRF-sensitive PKCE record.
///
/// Expiry is read from each record's own `ttlMs`, not from a store-wide
/// setting, so the TTL the caller configured on `WebConfig` is the one that
/// applies.
final class SessionStoragePendingGrantStore implements IPendingGrantStore {
  const SessionStoragePendingGrantStore();

  @override
  void put(PendingGrant grant) {
    window.sessionStorage.setItem(
      '$_kPendingGrantPrefix${grant.state}',
      grant.toJsonString(),
    );
  }

  @override
  PendingGrant? takeValid(String state) {
    final key = '$_kPendingGrantPrefix$state';
    final raw = window.sessionStorage.getItem(key);
    if (raw == null) return null;
    window.sessionStorage.removeItem(key);
    try {
      final grant = PendingGrant.fromJsonString(raw);
      return grant.isExpired ? null : grant;
    } catch (_) {
      return null;
    }
  }

  @override
  bool isExpired(String state) {
    final raw = window.sessionStorage.getItem('$_kPendingGrantPrefix$state');
    if (raw == null) return false;
    try {
      return PendingGrant.fromJsonString(raw).isExpired;
    } catch (_) {
      return false;
    }
  }

  @override
  void sweepExpired() {
    final storage = window.sessionStorage;
    final keysToRemove = <String>[];
    for (var i = 0; i < storage.length; i++) {
      final key = storage.key(i);
      if (key == null || !key.startsWith(_kPendingGrantPrefix)) continue;
      final raw = storage.getItem(key);
      if (raw == null) continue;
      try {
        if (PendingGrant.fromJsonString(raw).isExpired) keysToRemove.add(key);
      } catch (_) {
        keysToRemove.add(key);
      }
    }
    for (final k in keysToRemove) {
      storage.removeItem(k);
    }
  }
}
