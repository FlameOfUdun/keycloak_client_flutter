import '../interfaces/login_strategy.dart';
import 'web_login_strategy.dart';

/// Returns the [WebLoginStrategy] on web platforms.
ILoginStrategy get defaultLoginStrategy => WebLoginStrategy();
