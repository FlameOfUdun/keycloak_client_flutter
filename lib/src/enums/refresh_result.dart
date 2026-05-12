import '../models/user_credentials.dart';

sealed class RefreshResult {
  const RefreshResult();
}

final class RefreshSuccess extends RefreshResult {
  final UserCredentials credentials;
  const RefreshSuccess(this.credentials);
}

final class RefreshTransientFailure extends RefreshResult {
  final Object? cause;
  const RefreshTransientFailure({this.cause});
}

final class RefreshPermanentFailure extends RefreshResult {
  const RefreshPermanentFailure();
}
