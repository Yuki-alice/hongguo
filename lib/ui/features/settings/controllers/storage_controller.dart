import 'package:flutter/foundation.dart';

import 'package:hoshi/data/app_contract.dart';

/// 下载目录用量与迁移状态。
class StorageController extends ChangeNotifier {
  StorageController(this.repository);

  final AppRepository repository;
  Map<String, dynamic>? _info;
  String? _error;
  bool _busy = false;
  bool _disposed = false;

  Map<String, dynamic>? get info => _info;
  String? get error => _error;
  bool get busy => _busy;

  Future<void> refresh() async {
    try {
      final info = await repository.storage();
      if (_disposed) return;
      _info = info;
      _error = null;
    } catch (error) {
      if (_disposed) return;
      _error = error.toString();
    }
    _notify();
  }

  Future<bool> move(String parent) async {
    if (_busy || _disposed) return false;
    _busy = true;
    _error = null;
    _notify();
    var moved = true;
    try {
      await repository.moveDownloads(parent);
      await refresh();
    } catch (error) {
      moved = false;
      _error = error.toString();
    } finally {
      _busy = false;
      _notify();
    }
    return moved;
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
