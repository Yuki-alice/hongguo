import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/domain/source_status.dart';

/// 站源管理页的轮询、任务与健康检查状态。
class SourcesController extends ChangeNotifier {
  SourcesController({
    required this.repository,
    required this.store,
    this.initialSource,
    this.drama,
  });

  final AppRepository repository;
  final LocalStore store;
  final String? initialSource;
  final Drama? drama;

  final _statuses = <String, SourceStatus>{};
  final _errors = <String, String>{};
  final _pending = <String>{};
  final _revisions = <String, int>{};
  final _expandedHealth = <String>{};
  Timer? _timer;
  bool _polling = false;
  int _ticks = 0;
  bool _disposed = false;

  SourceStatus? statusOf(String id) => _statuses[id];
  String errorOf(String id) => _errors[id] ?? '';
  bool pending(String id) => _pending.contains(id);
  bool healthExpanded(String id) => _expandedHealth.contains(id);

  void start() {
    unawaited(refresh());
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      _ticks++;
      if (_statuses.values.any((status) => status.retryAt != null)) {
        _notify();
      }
      if (_ticks % 2 == 0 &&
          (_statuses.values.any((status) => status.running) ||
              _ticks % 10 == 0)) {
        unawaited(refresh());
      }
    });
  }

  Future<void> refresh() async {
    if (_polling || _disposed) return;
    _polling = true;
    final epoch = store.profileEpoch;
    try {
      await Future.wait([
        for (final source in store.sources)
          () async {
            final revision = _revisions[source.id] ?? 0;
            try {
              final status = await repository.sourceStatus(source.id);
              if (_disposed ||
                  epoch != store.profileEpoch ||
                  revision != (_revisions[source.id] ?? 0)) {
                return;
              }
              _statuses[source.id] = status;
              _errors.remove(source.id);
              _notify();
            } catch (error) {
              if (_disposed ||
                  epoch != store.profileEpoch ||
                  revision != (_revisions[source.id] ?? 0)) {
                return;
              }
              _errors[source.id] = error.toString();
              _notify();
            }
          }(),
      ]);
    } finally {
      _polling = false;
    }
  }

  Future<void> run(SourceSite source, String operation) async {
    if (_pending.contains(source.id) || _disposed) return;
    final epoch = store.profileEpoch;
    _pending.add(source.id);
    _errors.remove(source.id);
    _revisions[source.id] = (_revisions[source.id] ?? 0) + 1;
    if (operation == 'check' || operation == 'checkCatalog') {
      _expandedHealth.add(source.id);
    }
    _notify();
    try {
      final status = operation == 'cancel'
          ? await repository.cancelSourceJob(source.id)
          : await repository.startSourceJob(
              source.id,
              operation,
              drama: source.id == drama?.source ? drama : null,
            );
      if (_disposed || epoch != store.profileEpoch) return;
      _statuses[source.id] = status;
      _notify();
    } catch (error) {
      if (_disposed || epoch != store.profileEpoch) return;
      _errors[source.id] = error.toString();
      _notify();
    } finally {
      if (!_disposed) {
        _pending.remove(source.id);
        _notify();
      }
    }
  }

  void toggleHealth(String id) {
    if (!_expandedHealth.remove(id)) {
      _expandedHealth.add(id);
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
