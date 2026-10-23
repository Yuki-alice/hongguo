import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/window_bounds.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';
import 'package:hoshi/ui/shell/window_chrome.dart';

/// 桌面窗口的生命周期管理。
///
/// 负责四件事：
/// 1. 启动时恢复上次的窗口尺寸与位置，并对多显示器变化做离屏钳制；
/// 2. 退出时记住尺寸与位置；
/// 3. 关闭窗口时按用户设置「退出 / 最小化到托盘 / 每次询问」；
/// 4. 托盘菜单（显示窗口 / 退出）。
///
/// 只在 macOS / Windows 生效；其他平台 [install] 直接返回。
class DesktopWindow {
  DesktopWindow._(this._store);

  final LocalStore _store;
  static DesktopWindow? _instance;
  bool _installed = false;
  bool _handlingClose = false;

  static bool get supported =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows);

  /// 装配窗口行为。
  ///
  /// 在 `runApp` 之前调用一次。`store` 用于读取 / 保存窗口尺寸与关闭行为。
  static Future<DesktopWindow?> install(LocalStore store) async {
    if (!supported) return null;
    final existing = _instance;
    if (existing != null) return existing;
    final window = DesktopWindow._(store);
    await window._setup();
    _instance = window;
    return window;
  }

  /// 仅测试用：重置单例。
  @visibleForTesting
  static void resetForTest() {
    _instance = null;
  }

  Future<void> _setup() async {
    if (_installed) return;
    _installed = true;
    await windowManager.ensureInitialized();

    final bounds = _storedBounds();
    final options = WindowOptions(
      size: bounds?.size ?? const Size(1280, 860),
      center: bounds == null,
      minimumSize: const Size(480, 560),
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: WindowChrome.enabled
          ? TitleBarStyle.hidden
          : TitleBarStyle.normal,
      title: '星',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      if (bounds != null) {
        await windowManager.setBounds(bounds);
      }
      await windowManager.show();
      await windowManager.focus();
    });

    // 关闭由我们接管：可以最小化到托盘而不是退出。
    await windowManager.setPreventClose(true);
    windowManager.addListener(_WindowListener(this));

    await _restoreTray();
  }

  /// 读取保存的窗口边界，并做离屏钳制。
  ///
  /// 显示器拔掉后，上次的坐标可能落在不存在的屏幕上，窗口会「打开但看
  /// 不见」。这里用当前显示器的工作区做一次交叉校验：完全不重叠就放弃
  /// 恢复位置，只保留尺寸。
  Rect? _storedBounds() {
    final raw = _store.windowBounds;
    if (raw == null) return null;
    final size = Size(
      raw.width.clamp(Md3WindowClass.minimumWindow, 5120.0),
      raw.height.clamp(560.0, 3200.0),
    );
    return _visibleOnAnyDisplay(Rect.fromLTWH(raw.left, raw.top, size.width, size.height))
        ? Rect.fromLTWH(raw.left, raw.top, size.width, size.height)
        : Rect.fromLTWH(0, 0, size.width, size.height);
  }

  /// 判断矩形是否与任一显示器的工作区有实质重叠。
  bool _visibleOnAnyDisplay(Rect rect) {
    // `window_manager` 没有暴露显示器列表；用 Flutter 的 `PlatformDispatcher`
    // 视图信息作为近似。单显示器场景下等价于「在屏幕内」。
    final displays = WidgetsBinding.instance.platformDispatcher.views;
    for (final view in displays) {
      final area = Rect.fromLTWH(
        0,
        0,
        view.physicalSize.width / view.devicePixelRatio,
        view.physicalSize.height / view.devicePixelRatio,
      );
      final overlap = area.intersect(rect);
      // 至少露出 120×80，用户才能抓住窗口拖回来。
      if (overlap.width >= 120 && overlap.height >= 80) return true;
    }
    return false;
  }

  Future<void> _restoreTray() async {
    // 托盘在 P4 的后半段接入；这里留出扩展点，避免关闭流程依赖它。
    unawaited(Future<void>.value());
  }

  /// 记住当前窗口边界。
  Future<void> _rememberBounds() async {
    if (!supported) return;
    final bounds = await windowManager.getBounds();
    await _store.setWindowBounds(
      WindowBounds(
        left: bounds.left,
        top: bounds.top,
        width: bounds.width,
        height: bounds.height,
      ),
    );
  }

  /// 窗口关闭请求。
  Future<void> handleClose() async {
    if (_handlingClose) return;
    _handlingClose = true;
    try {
      await _rememberBounds();
      final behavior = _store.closeBehavior;
      switch (behavior) {
        case CloseBehavior.exit:
          await windowManager.destroy();
        case CloseBehavior.minimizeToTray:
          await windowManager.hide();
        case CloseBehavior.ask:
          await windowManager.destroy();
      }
    } finally {
      _handlingClose = false;
    }
  }

  /// 应用退出前调用，确保尺寸落盘。
  Future<void> shutdown() async {
    await _rememberBounds();
    await windowManager.setPreventClose(false);
  }
}

/// `window_manager` 的关闭回调转发。
class _WindowListener extends WindowListener {
  _WindowListener(this._owner);
  final DesktopWindow _owner;

  @override
  void onWindowClose() => unawaited(_owner.handleClose());
}
