import 'package:flutter/foundation.dart';

import 'package:duanju_app/data/core_bridge.dart';
import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/domain/models.dart';
import 'package:duanju_app/ui/core/app_l10n.dart';

/// 播放进度持久化。
///
/// 只管「当前打开的是哪一集、续播位置、保存去重与失败提示」，
/// 不持有播放器、页面或导航状态。
class PlaybackProgressController extends ChangeNotifier {
  PlaybackProgressController({
    required this.repository,
    required this.store,
    required this.drama,
    required this.episodes,
    required this.profileEpoch,
    this.mediaId,
    this.onFlush,
  });

  final AppRepository repository;
  final LocalStore store;
  final Drama drama;
  final List<Episode> episodes;
  final int profileEpoch;
  final String? mediaId;
  final VoidCallback? onFlush;

  int _openedIndex = -1;
  double _resumePosition = 0;
  String? _savedKey;
  String? _warning;
  bool _disposed = false;

  int get openedIndex => _openedIndex;
  double get resumePosition => _resumePosition;
  String? get warning => _warning;

  bool get canSave => _openedIndex >= 0 && store.profileEpoch == profileEpoch;

  void markOpened(int index) {
    _openedIndex = index;
  }

  void close() {
    _openedIndex = -1;
  }

  void setResumePosition(double seconds) {
    _resumePosition = seconds;
  }

  void notePosition(Duration position, int index) {
    if (_openedIndex == index && position > Duration.zero) {
      _resumePosition = position.inMilliseconds / 1000;
    }
  }

  Future<void> save({
    required Duration position,
    required Duration duration,
    bool flush = false,
  }) async {
    if (!canSave) return;
    final seconds = position.inMilliseconds / 1000;
    final total = duration.inMilliseconds / 1000;
    if (seconds < .1) return;
    final key = '${mediaId ?? drama.id}:$_openedIndex:$seconds:$total';
    if (_savedKey == key && _warning == null) {
      if (flush && mediaId == null) onFlush?.call();
      return;
    }
    final entry = WatchEntry(
      drama: repository.catalogUpdates.current(drama),
      episode: episodes[_openedIndex].number,
      position: seconds,
      duration: total,
      updatedAt: DateTime.now(),
    );
    try {
      await Future<void>.value();
      if (store.profileEpoch != profileEpoch) return;
      if (mediaId == null) {
        await store.saveWatch(entry);
        if (flush) onFlush?.call();
      } else {
        await store.saveMediaWatch(mediaId!, entry);
      }
      _savedKey = key;
      if (_warning != null) {
        _warning = null;
        if (!_disposed) notifyListeners();
      }
    } catch (_) {
      if (!_disposed && _warning == null) {
        _warning = AppL10n.current.progressSaveFailed;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
