/// User information model.
final class UserInfo {
  /// Unique identifier of the user. Always present — derived from the `sub` claim.
  final String id;

  /// Username of the user. Requires the `profile` scope. May be null if scope is not requested.
  final String? username;

  /// First name of the user. Requires the `profile` scope. May be null if scope is not requested or not set on the account.
  final String? givenName;

  /// Last name of the user. Requires the `profile` scope. May be null if scope is not requested or not set on the account.
  final String? familyName;

  /// Email address of the user. Requires the `email` scope. May be null if scope is not requested.
  final String? email;

  /// Whether the user's email is verified. Requires the `email` scope. May be null if scope is not requested.
  final bool? emailVerified;

  const UserInfo({
    required this.id,
    this.username,
    this.givenName,
    this.familyName,
    this.email,
    this.emailVerified,
  });

  /// Creates a User instance from a JSON map, typically returned by the API.
  factory UserInfo.fromApi(Map<String, dynamic> json) {
    return UserInfo(
      id: json['sub'] as String,
      username: json['preferred_username'] as String?,
      givenName: json['given_name'] as String?,
      familyName: json['family_name'] as String?,
      email: json['email'] as String?,
      emailVerified: json['email_verified'] as bool?,
    );
  }

  /// Creates a User instance from a JSON map, typically used for local storage.
  factory UserInfo.fromJson(Map<String, dynamic> json) {
    return UserInfo(
      id: json['id'] as String,
      username: json['username'] as String?,
      givenName: json['givenName'] as String?,
      familyName: json['familyName'] as String?,
      email: json['email'] as String?,
      emailVerified: json['emailVerified'] as bool?,
    );
  }

  /// Converts the User instance to a JSON map for storage.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'givenName': givenName,
      'familyName': familyName,
      'email': email,
      'emailVerified': emailVerified,
    };
  }
}
