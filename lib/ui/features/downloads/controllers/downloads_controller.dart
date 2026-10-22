import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:hoshi/data/core_bridge.dart';
import 'package:hoshi/domain/download_collections.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/ui/core/app_l10n.dart';

/// 下载合集页的取数、筛选、多选与批量操作状态机。
///
/// 删除确认、SnackBar 和导航仍由页面负责；提示文案通过 [takeMessage]
/// 交给页面消费，控制器不依赖 `BuildContext`。
class DownloadsController extends ChangeNotifier {
  DownloadsController({required this.repository, required this.store})
    : _epoch = store.profileEpoch {
    updater = DownloadCollectionUpdater(repository, store)
      ..addListener(_changed);
    store.addListener(_changed);
    unawaited(refresh());
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => refresh());
  }

  final AppRepository repository;
  final LocalStore store;
  final int _epoch;
  late final DownloadCollectionUpdater updater;
  Timer? _timer;

  List<DownloadJob> _jobs = const [];
  final _selected = <String>{};
  final _expanded = <String>{};
  bool _loading = true;
  bool _refreshing = false;
  bool _selecting = false;
  bool _busy = false;
  bool _stopBatch = false;
  bool _disposed = false;
  String? _error;
  String? _retryCommand;
  String _filter = 'all';
  String _release = '';
  String _operation = '';
  String _query = '';
  String? _message;

  List<DownloadJob> get jobs => UnmodifiableListView(_jobs);
  Iterable<DownloadJob> get selectedJobs =>
      _jobs.where((job) => _selected.contains(job.id));
  Set<String> get selected => UnmodifiableSetView(_selected);
  Set<String> get expanded => UnmodifiableSetView(_expanded);
  bool get loading => _loading;
  bool get selecting => _selecting;
  bool get busy => _busy;
  bool get hasError => _error != null;
  String? get error => _error;
  String? get retryCommand => _retryCommand;
  String get filter => _filter;
  String get release => _release;
  String get operation => _operation;
  String get query => _query;

  bool get allowed => store.profileEpoch == _epoch && store.canDownload;

  List<DownloadCollection> get collections => downloadCollections(
    _jobs,
    query: _query,
    filter: _filter,
    release: _release,
  );

  /// 消费一次操作提示，避免在构建阶段弹 SnackBar。
  String? takeMessage() {
    final message = _message;
    _message = null;
    return message;
  }

  Future<void> refresh() async {
    if (_refreshing || _disposed || !allowed) return;
    _refreshing = true;
    try {
      final jobs = await repository.downloads();
      if (_disposed || !allowed) return;
      _jobs = jobs;
      _selected.retainAll(jobs.map((job) => job.id));
      _error = null;
    } catch (error) {
      if (_disposed || !allowed) return;
      _error = error.toString();
    } finally {
      _refreshing = false;
      if (!_disposed) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  List<DownloadJob> targets(String command, Iterable<DownloadJob> source) =>
      source
          .where(
            (job) => switch (command) {
              'pause' => job.active,
              'resume' => job.resumable,
              'archive' => job.completed && !job.archived,
              'restore' => job.completed && job.archived,
              'remove' => true,
              _ => false,
            },
          )
          .toList();

  Future<void> batch(String command, Iterable<DownloadJob> source) async {
    if (_busy || _disposed || !allowed) return;
    final jobs = targets(command, source);
    if (jobs.isEmpty) {
      _message = AppL10n.current.noSuitableTasksController;
      notifyListeners();
      return;
    }
    _busy = true;
    _stopBatch = false;
    _retryCommand = null;
    notifyListeners();
    final failures = <String, String>{};
    var completed = 0;
    try {
      for (var offset = 0; offset < jobs.length; offset += 500) {
        if (_disposed || !allowed || _stopBatch) break;
        _operation = AppL10n.current.downloadProcessing(
          math.min(offset + 500, jobs.length),
          jobs.length,
        );
        notifyListeners();
        final ids = jobs
            .sublist(offset, math.min(offset + 500, jobs.length))
            .map((job) => job.id)
            .toList();
        try {
          final result = await repository.controlDownloadBatch(command, ids);
          if (_disposed || !allowed) return;
          completed += result.completed.length;
          _selected.removeAll(result.completed);
          failures.addAll(result.failures);
        } catch (error) {
          failures.addAll({for (final id in ids) id: error.toString()});
        }
      }
      if (_disposed || !allowed) return;
      if (failures.isNotEmpty) {
        _selected.addAll(failures.keys);
        _selecting = true;
        _retryCommand = command;
        _message = AppL10n.current.downloadProcessedFailures(
          completed,
          failures.length,
          failures.values.first,
        );
      } else {
        _message = _stopBatch
            ? AppL10n.current.downloadStoppedProcessed(completed)
            : command == 'archive'
            ? AppL10n.current.downloadArchivedProcessed(completed)
            : AppL10n.current.downloadProcessed(completed);
      }
      await refresh();
    } finally {
      if (!_disposed) {
        _busy = false;
        _operation = '';
        notifyListeners();
      }
    }
  }

  Future<void> updateCollection(Drama drama) async {
    await updater.update(drama);
    if (_disposed || !allowed) return;
    _message = updater.error ?? updater.status;
    await refresh();
  }

  void stopBatch() => _stopBatch = true;

  void select(Iterable<DownloadJob> jobs) {
    final ids = jobs.map((job) => job.id).toSet();
    _selecting = true;
    if (ids.every(_selected.contains)) {
      _selected.removeAll(ids);
    } else {
      _selected.addAll(ids);
    }
    notifyListeners();
  }

  void startSelecting() {
    if (_selecting) return;
    _selecting = true;
    notifyListeners();
  }

  void exitSelecting() {
    _selecting = false;
    _selected.clear();
    _retryCommand = null;
    notifyListeners();
  }

  void toggleExpanded(String dramaId) {
    if (!_expanded.remove(dramaId)) {
      _expanded.add(dramaId);
    }
    notifyListeners();
  }

  void applyFilters({required String filter, required String release}) {
    if (_filter == filter && _release == release) return;
    _filter = filter;
    _release = release;
    notifyListeners();
  }

  void setQuery(String value) {
    if (_query == value) return;
    _query = value;
    notifyListeners();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopBatch = true;
    _timer?.cancel();
    store.removeListener(_changed);
    updater.removeListener(_changed);
    updater.dispose();
    super.dispose();
  }
}
