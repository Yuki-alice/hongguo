import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'package:hoshi/ui/shell/desktop_window.dart';

/// 桌面托盘。
///
/// 只在「关闭时最小化到托盘」被选中时才真正需要，但始终创建：用户可能
/// 在运行期改设置，托盘图标应该已经在了。
///
/// 菜单两项：显示窗口 / 退出。退出走 `DesktopWindow.shutdown`，确保窗口
/// 尺寸落盘。
class DesktopTray with TrayListener {
  DesktopTray._(this._window);

  final DesktopWindow _window;
  static DesktopTray? _instance;

  static bool get supported =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows);

  static Future<DesktopTray?> install(DesktopWindow window) async {
    if (!supported) return null;
    final existing = _instance;
    if (existing != null) return existing;
    final tray = DesktopTray._(window);
    await tray._setup();
    _instance = tray;
    return tray;
  }

  Future<void> _setup() async {
    trayManager.addListener(this);
    try {
      await trayManager.setIcon(_iconPath());
      await trayManager.setToolTip('星');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: '显示窗口'),
            MenuItem.separator(),
            MenuItem(key: 'exit', label: '退出'),
          ],
        ),
      );
    } catch (error) {
      // 托盘不可用（例如 Linux 无桌面环境）不应该影响应用启动。
      debugPrint('tray unavailable: $error');
    }
  }

  /// 图标路径。
  ///
  /// 用打包进 Flutter 资源的图标，而不是去猜原生目录：Windows 要 ico，
  /// macOS 用 png（模板图由系统自动适配菜单栏明暗）。
  String _iconPath() {
    if (Platform.isWindows) return 'assets/images/logo/tray.ico';
    return 'assets/images/logo/tray.png';
  }

  @override
  void onTrayIconMouseDown() => unawaited(windowManager.show());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(windowManager.show());
        unawaited(windowManager.focus());
      case 'exit':
        unawaited(_exit());
    }
  }

  Future<void> _exit() async {
    await _window.shutdown();
    exit(0);
  }

  static Future<void> dispose() async {
    final tray = _instance;
    if (tray == null) return;
    trayManager.removeListener(tray);
    _instance = null;
  }
}
