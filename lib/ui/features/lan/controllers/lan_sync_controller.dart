import 'package:flutter/foundation.dart';

import 'package:duanju_app/data/lan/lan_controller.dart';

/// 局域网同步页的动作状态：忙碌标记、取消标记与错误文案。
///
/// 页面只负责弹对话框、导航与渲染，状态迁移全部集中在这里，
/// 使「同一时刻只允许一个动作」与「错误在下一次动作前清除」这两条
/// 规则只有一处实现。
class LanSyncController extends ChangeNotifier {
  LanSyncController({required this.link});

  final LanController link;

  bool _busy = false;
  bool _cancelling = false;
  String? _error;
  bool _disposed = false;

  bool get busy => _busy;
  bool get cancelling => _cancelling;
  String? get error => _error;

  bool get controlsEnabled =>
      !_busy && !_cancelling && !link.syncing && !link.store.locked;

  Future<void> perform(Future<void> Function() action) async {
    if (_busy || _disposed) return;
    _busy = true;
    _error = null;
    _notify();
    try {
      await action();
    } catch (error) {
      _error = error.toString();
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> cancelSync() async {
    if (_cancelling || _disposed) return;
    _cancelling = true;
    _notify();
    try {
      await link.cancelSync();
    } catch (error) {
      _error = error.toString();
    } finally {
      _cancelling = false;
      _notify();
    }
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
