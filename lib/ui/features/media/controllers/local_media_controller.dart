import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'package:hoshi/data/core_bridge.dart';
import 'package:hoshi/data/media/media_library.dart';
import 'package:hoshi/domain/models.dart';

/// 本地媒体页依赖的媒体操作端口。
///
/// `exportMerged` 定义在 `MediaLibrary` 的扩展上，无法通过继承替换；
/// 用端口隔离后控制器可以在测试中注入假实现。
abstract interface class LocalMediaOperations {
  Future<void> reload();
  Future<void> exportJobs(List<DownloadJob> selected);
  Future<LocalMediaItem> exportMerged(LocalMediaItem selected);
  Future<void> remove(LocalMediaItem selected);
}

class MediaLibraryOperations implements LocalMediaOperations {
  MediaLibraryOperations(this.library);

  final MediaLibrary library;

  @override
  Future<void> reload() => library.reload();

  @override
  Future<void> exportJobs(List<DownloadJob> selected) =>
      library.exportJobs(selected);

  @override
  Future<LocalMediaItem> exportMerged(LocalMediaItem selected) =>
      library.exportMerged(selected);

  @override
  Future<void> remove(LocalMediaItem selected) => library.remove(selected);
}

/// 本地媒体页的数据状态。
///
/// 合并队列、文件选择与播放导航仍由页面负责；这里只管下载任务、
/// 加载/错误标记与导出/删除操作。
class LocalMediaController extends ChangeNotifier {
  LocalMediaController({
    required this.repository,
    required this.library,
    LocalMediaOperations? operations,
  }) : operations = operations ?? MediaLibraryOperations(library);

  final AppRepository repository;
  final MediaLibrary library;
  final LocalMediaOperations operations;

  List<DownloadJob> _jobs = const [];
  bool _loading = true;
  bool _merged = true;
  String? _error;
  bool _disposed = false;

  List<DownloadJob> get jobs => UnmodifiableListView(_jobs);
  bool get loading => _loading;
  bool get merged => _merged;
  String? get error => _error;

  void showMerged(bool value) {
    if (_merged == value) return;
    _merged = value;
    _notify();
  }

  Future<void> load() async {
    try {
      final jobs = await repository.downloads();
      await operations.reload();
      if (_disposed) return;
      _jobs = jobs.where((job) => job.completed).toList();
      _error = null;
    } catch (error) {
      if (_disposed) return;
      _error = error.toString();
    } finally {
      if (!_disposed) {
        _loading = false;
        _notify();
      }
    }
  }

  Future<bool> exportJobs(List<DownloadJob> selected) async {
    _merged = false;
    _error = null;
    _notify();
    try {
      await operations.exportJobs(selected);
      await load();
      return true;
    } catch (error) {
      if (_disposed) return false;
      _error = error.toString();
      _notify();
      return false;
    }
  }

  Future<bool> exportMerged(LocalMediaItem item) async {
    try {
      await operations.exportMerged(item);
      if (_disposed) return false;
      _merged = false;
      _error = null;
      _notify();
      return true;
    } catch (error) {
      if (_disposed) return false;
      _error = error.toString();
      _notify();
      return false;
    }
  }

  Future<bool> remove(LocalMediaItem item) async {
    try {
      await operations.remove(item);
      return true;
    } catch (error) {
      if (_disposed) return false;
      _error = error.toString();
      _notify();
      return false;
    }
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
