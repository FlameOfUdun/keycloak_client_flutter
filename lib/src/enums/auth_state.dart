/// Authentication states
enum AuthState {
  /// Initial state, not yet determined.
  unknown,

  /// User explicitly logged out.
  signedOut,

  /// User is signed in with valid session.
  signedIn,

  /// Session ended because the refresh token expired. The user must log in again.
  sessionExpired,

  /// Session ended because the principal lacks a role listed in
  /// `ClientConfig.requiredRealmRoles` / `requiredClientRoles`, either at
  /// restore or because it was revoked while signed in.
  accessDenied;

  bool get isUnknown => this == AuthState.unknown;
  bool get isSignedOut => this == AuthState.signedOut;
  bool get isSignedIn => this == AuthState.signedIn;
  bool get isSessionExpired => this == AuthState.sessionExpired;
  bool get isAccessDenied => this == AuthState.accessDenied;
}
