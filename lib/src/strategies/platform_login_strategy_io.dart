import 'package:flutter/foundation.dart';

import '../interfaces/login_strategy.dart';
import 'desktop_login_strategy.dart';
import 'mobile_login_strategy.dart';

/// Returns the correct [ILoginStrategy] for the current non-web platform.
///
/// Desktop-specific listener settings are supplied via
/// [DesktopPlatformConfig] when the platform is desktop
/// (Windows, macOS, Linux); ignored on mobile.
ILoginStrategy get defaultLoginStrategy {
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => const MobileLoginStrategy(),
    _ => DesktopLoginStrategy(),
  };
}
