import '../enums/log_level.dart';
import 'platform_config.dart';

final class ClientConfig {
  final String baseUrl;
  final String realm;
  final String clientId;
  final String? clientSecret;
  final List<String> scopes;
  final LogLevel logLevel;
  final DesktopConfig desktop;
  final MobileConfig mobile;
  final WebConfig web;

  const ClientConfig({
    required this.baseUrl,
    required this.realm,
    required this.clientId,
    this.clientSecret,
    this.scopes = const ['openid', 'email', 'profile'],
    this.logLevel = LogLevel.trace,
    this.desktop = const DesktopConfig(),
    this.mobile = const MobileConfig(),
    this.web = const WebConfig(),
  });

  Uri get authorizationEndpoint => Uri.parse('$baseUrl/realms/$realm/protocol/openid-connect/auth');
  Uri get tokenEndpoint => Uri.parse('$baseUrl/realms/$realm/protocol/openid-connect/token');
  Uri get userInfoEndpoint => Uri.parse('$baseUrl/realms/$realm/protocol/openid-connect/userinfo');
  Uri get logoutEndpoint => Uri.parse('$baseUrl/realms/$realm/protocol/openid-connect/logout');
}
