import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/ui/core/episode_browser.dart';
import 'package:hoshi/domain/follow_state.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/ui/core/app_l10n.dart';

/// 详情页的取数与状态机。
///
/// 只管数据：取详情、合并目录资料、补充元数据、计算剧集分页，并通过
/// [LocalStore] 的通知保持权限与追剧状态同步。导航、对话框、SnackBar
/// 仍由页面负责，因此这里不依赖 `BuildContext`。
class DetailController extends ChangeNotifier {
  DetailController({
    required this.drama,
    required this.repository,
    required this.store,
  }) : _profileEpoch = store.profileEpoch {
    store.addListener(_onStoreChanged);
  }

  final Drama drama;
  final AppRepository repository;
  final LocalStore store;

  final int _profileEpoch;
  int _generation = 0;
  bool _disposed = false;
  DramaDetail? _detail;
  String? _error;
  String? _saveError;
  bool _loading = true;
  int _episodePage = 0;

  DramaDetail? get detail => _detail;
  String? get error => _error;
  bool get loading => _loading;
  int get episodePage => _episodePage;
  Drama get currentDrama => _detail?.drama ?? drama;

  bool get allowed =>
      store.profileEpoch == _profileEpoch &&
      store.allowsSource(currentDrama.source);

  /// 消费一次保存失败提示，避免在构建阶段弹 SnackBar。
  String? takeSaveError() {
    final error = _saveError;
    _saveError = null;
    return error;
  }

  /// 重新取详情。成功返回 true，调用方据此决定是否执行首屏动作。
  Future<bool> load() async {
    final generation = ++_generation;
    final changed = !_loading || _error != null;
    _loading = true;
    _error = null;
    if (changed) notifyListeners();
    try {
      final detail = await repository.detail(drama);
      if (_disposed ||
          generation != _generation ||
          _profileEpoch != store.profileEpoch) {
        return false;
      }
      final merged = repository.catalogUpdates
          .current(drama)
          .merge(detail.drama);
      _detail = DramaDetail(merged, detail.episodes, warning: detail.warning);
      _loading = false;
      _episodePage =
          resumeEpisodeIndex(detail.episodes, store.watched(merged.id)) ~/
          episodePageSize;
      notifyListeners();
      repository.catalogUpdates.publish(merged, retryCover: true);
      unawaited(_supplement(merged, generation));
      await _save(() => store.refreshDrama(merged));
      return true;
    } catch (error) {
      if (_disposed || generation != _generation) return false;
      _error = error.toString();
      _loading = false;
      notifyListeners();
      repository.catalogUpdates.publish(
        repository.catalogUpdates.current(drama),
        retryCover: true,
      );
      return false;
    }
  }

  Future<void> _supplement(Drama drama, int generation) async {
    try {
      final fresh = await repository.supplementMetadata(drama);
      if (_disposed ||
          generation != _generation ||
          fresh == null ||
          _detail == null) {
        return;
      }
      final updated = _detail!.drama.merge(fresh);
      _detail = DramaDetail(
        updated,
        _detail!.episodes,
        warning: _detail!.warning,
      );
      notifyListeners();
      repository.catalogUpdates.publish(updated);
      await _save(() => store.refreshDrama(updated));
    } catch (_) {}
  }

  Future<void> _save(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      _saveError = AppL10n.current.detailSaveFailed;
      if (!_disposed) notifyListeners();
    }
  }

  void setEpisodePage(int index) {
    final page = index ~/ episodePageSize;
    if (page == _episodePage) return;
    _episodePage = page;
    notifyListeners();
  }

  void _onStoreChanged() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    store.removeListener(_onStoreChanged);
    super.dispose();
  }
}
