import 'package:flutter/foundation.dart';

import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/playback_preferences.dart';

/// 播放器运行期偏好：速度、自动连播、弹幕与预加载开关。
///
/// 清晰度由 [PlaybackSessionController] 持有，增强偏好由
/// `VideoEnhancementController` 持有，这里只负责播放器自身的偏好与持久化。
class PlaybackPreferencesController extends ChangeNotifier {
  PlaybackPreferencesController({
    required this.store,
    required this.profileEpoch,
    required PlaybackPreferences initial,
  }) : _speed = initial.speed,
       _autoAdvance = initial.autoAdvance,
       _danmakuEnabled = initial.danmaku;

  final LocalStore store;
  final int profileEpoch;

  double _speed;
  bool _autoAdvance;
  bool _danmakuEnabled;
  final bool _preloadEnabled = true;
  bool _disposed = false;

  double get speed => _speed;
  bool get autoAdvance => _autoAdvance;
  bool get danmakuEnabled => _danmakuEnabled;
  bool get preloadEnabled => _preloadEnabled;

  Future<bool> save(PlaybackPreferences next) async {
    final merged = next.copyWith(preload: true);
    await store.setPlaybackPreferences(merged);
    if (_disposed || store.profileEpoch != profileEpoch) return false;
    _speed = merged.speed;
    _autoAdvance = merged.autoAdvance;
    _danmakuEnabled = merged.danmaku;
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
