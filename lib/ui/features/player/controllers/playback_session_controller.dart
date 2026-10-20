import 'package:flutter/foundation.dart';

import 'package:duanju_app/domain/models.dart';
import 'package:duanju_app/ui/core/app_l10n.dart';

/// 播放会话的加载、错误与线路状态。
///
/// 只管「当前集、请求清晰度、播放计划、加载/错误标记」以及 generation
/// 闸门；播放器操作、弹幕、下载与页面导航仍由 `PlayerScreen` 负责。
class PlaybackSessionController extends ChangeNotifier {
  PlaybackSessionController({required int index, required int quality}) {
    _index = index;
    _requestedQuality = quality;
  }

  int _index = 0;
  int _generation = 0;
  int _requestedQuality = 0;
  bool _loading = true;
  bool _forceOnline = false;
  bool _localFailure = false;
  bool _showControlsOnPlaybackReady = true;
  String _loadingMessage = AppL10n.current.playerPreparing;
  String? _error;
  PlaybackPlan? _plan;
  bool _disposed = false;

  int get index => _index;
  int get generation => _generation;
  int get requestedQuality => _requestedQuality;
  bool get loading => _loading;
  bool get forceOnline => _forceOnline;
  bool get localFailure => _localFailure;
  bool get showControlsOnPlaybackReady => _showControlsOnPlaybackReady;
  String get loadingMessage => _loadingMessage;
  String? get error => _error;
  PlaybackPlan? get plan => _plan;
  bool get ready => !_loading && _error == null;
  String get qualityLabel => _plan?.local == true
      ? AppL10n.current.localOriginal
      : _requestedQuality == 0
      ? AppL10n.current.automatic
      : '${_requestedQuality}P';
  String get session => _plan?.session ?? '';

  /// 开始一次取流，递增 generation 并返回本轮票据。
  int begin({
    required int index,
    required String message,
    required bool showControlsOnReady,
  }) {
    _generation++;
    if (index != _index) _forceOnline = false;
    _index = index;
    _loading = true;
    _error = null;
    _localFailure = false;
    _loadingMessage = message;
    _showControlsOnPlaybackReady = showControlsOnReady;
    _notify();
    return _generation;
  }

  void finish({required PlaybackPlan plan, int? index}) {
    if (index != null) _index = index;
    _plan = plan;
    _loading = false;
    _notify();
  }

  void fail({required String message, required bool localFailure}) {
    _loading = false;
    _localFailure = localFailure;
    _error = message;
    _notify();
  }

  void setPlan(PlaybackPlan? value) {
    if (identical(_plan, value)) return;
    _plan = value;
    _notify();
  }

  void setRequestedQuality(int value) {
    if (_requestedQuality == value) return;
    _requestedQuality = value;
    _notify();
  }

  void setForceOnline(bool value) {
    if (_forceOnline == value) return;
    _forceOnline = value;
    _notify();
  }

  void invalidate() {
    _generation++;
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
