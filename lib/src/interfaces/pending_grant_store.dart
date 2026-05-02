import '../models/pending_grant.dart';

/// Persists [PendingGrant] records across the OAuth redirect.
///
/// Implementations must namespace their keys (the production impl uses
/// `keycloak_client.pending.<state>`) so [sweepExpired] never touches
/// records owned by other code.
abstract interface class IPendingGrantStore {
  /// Persists [grant], overwriting any existing record with the same state.
  void put(PendingGrant grant);

  /// Removes and returns the grant for [state] if it exists and is within
  /// the store's TTL. Returns null in every other case (missing, expired,
  /// or malformed). Expired and malformed records are removed.
  /// Subsequent calls with the same state return null.
  PendingGrant? takeValid(String state);

  /// True if a record exists for [state] and is past the TTL. Returns false
  /// for missing or malformed records. Does not mutate storage. Used by
  /// callers that need to distinguish "unknown state" from "timed out".
  bool isExpired(String state);

  /// Removes every expired or malformed record owned by this store,
  /// including ones whose `state` was never returned via [takeValid]
  /// (abandoned flows). Should be called at the start of
  /// `WebLoginStrategy.handleCallback` to bound storage growth.
  void sweepExpired();
}
