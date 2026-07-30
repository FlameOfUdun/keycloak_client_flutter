import 'dart:math';

/// The unreserved character set RFC 7636 §4.1 allows in a code verifier.
const _verifierAlphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

final _rng = Random.secure();

/// A 64-character PKCE code verifier.
///
/// RFC 7636 §4.1 permits 43–128 characters from the unreserved set; 64 sits
/// comfortably inside that and yields ~380 bits of entropy from
/// [Random.secure].
String generateCodeVerifier() => List.generate(
  64,
  (_) => _verifierAlphabet[_rng.nextInt(_verifierAlphabet.length)],
).join();

/// A 128-bit opaque `state` value, hex encoded.
///
/// RFC 6749 §10.12 requires this on every authorization request: it binds the
/// callback to the request that started it, so a `code` delivered by anyone
/// else is rejected before it is ever exchanged.
String generateState() => List.generate(
  16,
  (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
