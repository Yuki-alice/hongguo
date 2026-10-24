import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

export 'package:hoshi/app_build.dart';

/// 兜底版本号。
///
/// 真实版本在启动时由 [AppDevice.detect] 从平台读取（Android 走
/// `hoshi/device`，桌面走 `package_info_plus`），这里只用于测试与
/// 读不到平台信息时的显示。改动 pubspec 的 `version:` 后无需同步此处。
const appVersion = '0.2.62';

class AppDevice {
  const AppDevice({this.version = appVersion});
  final String version;
  static const channel = MethodChannel('hoshi/device');

  static Future<AppDevice> detect({
    AppDevice fallback = const AppDevice(),
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      final version = await _packageVersion();
      return AppDevice(version: version ?? fallback.version);
    }
    try {
      final data = await channel
          .invokeMapMethod<String, dynamic>('deviceInfo')
          .timeout(const Duration(seconds: 2));
      final version = data?['version'];
      return AppDevice(
        version: version is String && version.isNotEmpty
            ? version
            : fallback.version,
      );
    } on PlatformException {
      return fallback;
    } on MissingPluginException {
      return fallback;
    } on TimeoutException {
      return fallback;
    }
  }

  /// 桌面与 iOS 的版本号来自平台包信息。
  ///
  /// Android 由 `hoshi/device` 一并返回，其余平台没有自己的通道，
  /// 直接用 `package_info_plus`，避免把版本号
  /// 抄进 Dart 常量后在每次发版时忘记同步。
  static Future<String?> _packageVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isEmpty) return null;
      return info.buildNumber.isEmpty
          ? info.version
          : '${info.version}+${info.buildNumber}';
    } catch (_) {
      return null;
    }
  }
}

class AppLayout extends InheritedWidget {
  const AppLayout({super.key, this.version = appVersion, required super.child});
  final String version;

  static String versionOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppLayout>()?.version ??
      appVersion;

  @override
  bool updateShouldNotify(AppLayout oldWidget) => version != oldWidget.version;
}
