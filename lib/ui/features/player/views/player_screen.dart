import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import 'package:duanju_app/ui/core/app_layout.dart';
import 'package:duanju_app/ui/core/app_orientation.dart';
import 'package:duanju_app/ui/core/app_theme.dart';
import 'package:duanju_app/data/core_bridge.dart';
import 'package:duanju_app/ui/features/player/danmaku/danmaku_controller.dart';
import 'package:duanju_app/ui/features/player/danmaku/danmaku_overlay.dart';
import 'package:duanju_app/ui/features/downloads/widgets/download_picker.dart';
import 'package:duanju_app/domain/follow_state.dart';
import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/domain/models.dart';
import 'package:duanju_app/l10n/generated/app_localizations.dart';
import 'package:duanju_app/data/playback/playback_loader.dart';
import 'package:duanju_app/data/playback/playback_preloader.dart';
import 'package:duanju_app/data/playback/playback_recovery.dart';
import 'package:duanju_app/domain/playback_preferences.dart';
import 'package:duanju_app/ui/features/player/controllers/playback_preferences_controller.dart';
import 'package:duanju_app/ui/features/player/controllers/playback_progress_controller.dart';
import 'package:duanju_app/ui/features/player/controllers/playback_session_controller.dart';
import 'package:duanju_app/ui/features/player/widgets/player_controls.dart';
import 'package:duanju_app/ui/features/player/widgets/player_interactions.dart';
import 'package:duanju_app/ui/features/player/widgets/player_menu.dart';
import 'package:duanju_app/ui/features/player/widgets/television_controls.dart';
import 'package:duanju_app/ui/routing/app_router.dart';
import 'package:duanju_app/ui/core/widgets.dart';
import 'package:duanju_app/ui/features/sources/views/sources_screen.dart';
import 'package:duanju_app/data/lan/lan_controller.dart';
import 'package:duanju_app/ui/features/lan/views/lan_screen.dart';
import 'package:duanju_app/data/video_enhancement/video_enhancement.dart';
import 'package:duanju_app/data/video_enhancement/video_output_size.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.detail,
    required this.initialIndex,
    required this.repository,
    required this.store,
    this.initialPosition = 0,
    this.localOnly = false,
    this.allowOnlineFallback = true,
    this.mediaId,
    this.playerFactory,
    this.videoBuilder,
    this.handoff,
  });
  final DramaDetail detail;
  final int initialIndex;
  final double initialPosition;
  final bool localOnly;
  final bool allowOnlineFallback;
  final String? mediaId;
  final AppRepository repository;
  final LocalStore store;
  final LanIncomingPlayback? handoff;
  @visibleForTesting
  final Player Function()? playerFactory;
  @visibleForTesting
  final Widget Function(Widget controls)? videoBuilder;
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  AppLocalizations get l10n => AppLocalizations.of(context);
  late final Player _player;
  late final VideoController? _video;
  late final VideoEnhancementController _enhancement;
  late final PlaybackLoader _loader;
  late final PlaybackPreloader _preloader;
  late final DanmakuController _danmaku;
  int _seekSequence = 0;
  late final PlayerInteractions _interactions;
  final _playerFocus = FocusNode(debugLabel: 'player-surface');
  final _videoPaneKey = GlobalKey();
  final _menuRevision = ValueNotifier<int>(0);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final _recovery = PlaybackRecovery();
  Object _lanIdentity = Object();
  bool _handoffOwned = true;
  double? _lanFirstPosition;
  late final PlaybackProgressController _progress;
  late final PlaybackSessionController _playback;
  late final PlaybackPreferencesController _prefs;
  final _health = PlaybackHealth();
  Timer? _saveTimer;
  Timer? _healthTimer;
  Timer? _errorTimer;
  Timer? _pictureInPictureExitTimer;
  Future<void> _operations = Future<void>.value();
  late final int _profileEpoch;
  bool _fullscreen = false;
  bool _automaticFullscreenSuppressed = false;
  bool _panelOpen = false;
  int _mobileTab = 0;
  bool? _systemFullscreen;
  Orientation? _lastOrientation;
  bool _closed = false;
  bool _acceptErrors = false;
  bool _foreground = true;
  bool _playIntent = true;
  bool _pendingError = false;
  bool _pictureInPictureSupported = false;
  bool _pictureInPictureActive = false;
  bool _pictureInPictureRequested = false;
  bool _pictureInPictureHandlerInstalled = false;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  double _aspectRatio = 9 / 16;
  bool _rotating = false;
  bool _television = false;
  AppOrientationController? _orientationController;
  bool get _pictureInPictureVisible =>
      _pictureInPictureActive || _pictureInPictureRequested;
  bool get _canUsePictureInPicture =>
      !_television &&
      defaultTargetPlatform == TargetPlatform.android &&
      _pictureInPictureSupported;
  bool get _mobile =>
      !_television &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  VideoEnhancementController? get _enhancementForUi =>
      _enhancement.supported ? _enhancement : null;
  PlaybackPreferences get _preferences => PlaybackPreferences(
    speed: _prefs.speed,
    quality: _playback.requestedQuality,
    autoAdvance: _prefs.autoAdvance,
    danmaku: _prefs.danmakuEnabled,
    preload: _prefs.preloadEnabled,
    enhancement: _enhancement.preferences,
  );
  String get _qualityLabel => _playback.qualityLabel;
  String get _session => _playback.session;
  double get _currentPosition =>
      _progress.openedIndex == _playback.index &&
          _player.state.position.inMilliseconds > 0
      ? _player.state.position.inMilliseconds / 1000
      : _progress.resumePosition;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _profileEpoch = widget.handoff?.profileEpoch ?? widget.store.profileEpoch;
    final preferences = widget.store.playbackPreferences;
    _prefs = PlaybackPreferencesController(
      store: widget.store,
      profileEpoch: _profileEpoch,
      initial: preferences,
    )..addListener(_prefsChanged);
    _playback = PlaybackSessionController(
      index: widget.initialIndex,
      quality: preferences.quality,
    )..addListener(_playbackChanged);
    _progress = PlaybackProgressController(
      repository: widget.repository,
      store: widget.store,
      drama: widget.detail.drama,
      episodes: widget.detail.episodes,
      profileEpoch: _profileEpoch,
      mediaId: widget.mediaId,
      onFlush: () => LanController.current?.flush(),
    )..addListener(_progressChanged);
    _loader = PlaybackLoader(widget.repository);
    _preloader = PlaybackPreloader(widget.repository);
    _danmaku = DanmakuController(widget.repository)
      ..setEnabled(_prefs.danmakuEnabled);
    widget.store.addListener(_accessChanged);
    _player =
        widget.playerFactory?.call() ??
        Player(
          configuration: const PlayerConfiguration(
            bufferSize: 32 * 1024 * 1024,
            logLevel: MPVLogLevel.v,
          ),
        );
    _video = widget.videoBuilder == null
        ? VideoController(
            _player,
            configuration: VideoControllerConfiguration(
              enableHardwareAcceleration: !Platform.isIOS,
            ),
          )
        : null;
    _enhancement = VideoEnhancementController(
      player: _player,
      video: _video,
      preferences: preferences.enhancement,
      category: widget.detail.drama.category,
      tags: widget.detail.drama.tags,
    );
    _interactions = PlayerInteractions(
      player: _player,
      available: () =>
          !_closed &&
          widget.store.profileEpoch == _profileEpoch &&
          !_playback.loading &&
          _playback.error == null &&
          _foreground &&
          !_panelOpen,
      baseSpeed: () => _prefs.speed,
      onTogglePlayback: _togglePlayback,
      onSeek: _seekTo,
      onFullscreen: _rotate,
      onEpisode: (direction) {
        final next = _playback.index + direction;
        if (next < 0) return l10n.playerFirstEpisode;
        if (next >= widget.detail.episodes.length)
          return l10n.playerLastEpisode;
        unawaited(_play(next));
        return l10n.episodeTitle(widget.detail.episodes[next].number);
      },
    );
    _playerFocus.addListener(() {
      if (!_playerFocus.hasPrimaryFocus && !_closed) _interactions.cancel();
    });
    _configurePictureInPicture();
    _subscriptions.add(
      _player.stream.error.listen((error) {
        if (_enhancement.handlePlaybackError(error)) return;
        if (!_closed && _acceptErrors && mounted && error.trim().isNotEmpty) {
          _queueRecovery();
        }
      }),
    );
    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (completed &&
            !_playback.loading &&
            !_closed &&
            _acceptErrors &&
            _playback.error == null) {
          final duration = _player.state.duration;
          if (duration <= Duration.zero ||
              _player.state.position < duration - const Duration(seconds: 2)) {
            _queueRecovery();
          } else if (_prefs.autoAdvance &&
              _foreground &&
              !_panelOpen &&
              _playback.index + 1 < widget.detail.episodes.length) {
            _play(_playback.index + 1, showControlsOnReady: false);
          } else {
            _playIntent = false;
            _interactions.cancel();
            unawaited(_player.pause());
            unawaited(_saveProgress(flush: true));
          }
        }
      }),
    );
    _subscriptions.add(
      _player.stream.position.listen((position) {
        if (!_closed) _progress.notePosition(position, _playback.index);
        _syncDanmaku();
        _syncPreload();
        _acknowledgeHandoff();
      }),
    );
    for (final stream in [
      _player.stream.duration,
      _player.stream.buffer,
      _player.stream.playing,
      _player.stream.buffering,
      _player.stream.rate,
      _player.stream.completed,
    ]) {
      _subscriptions.add(
        stream.listen((_) {
          _syncDanmaku();
          _syncPreload();
          _acknowledgeHandoff();
        }),
      );
    }
    _subscriptions.add(
      _player.stream.videoParams.listen((parameters) {
        final size = videoDisplaySize(parameters);
        if (size != null && mounted && !_closed) {
          setState(() {
            _aspectRatio = size.width / size.height;
          });
          _scheduleSystemUi();
        }
      }),
    );
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_closed &&
          _acceptErrors &&
          !_playback.loading &&
          _playback.error == null &&
          _health.stalled(
            position: _player.state.position,
            playing: _player.state.playing && _playIntent,
            foreground: _foreground,
            now: DateTime.now(),
          )) {
        unawaited(_recover());
      }
    });
    final handoff = widget.handoff;
    if (handoff != null) {
      handoff.consumed = true;
      handoff.stop = () async {
        if (_handoffOwned && !_closed) await _stopForLan();
      };
    }
    if (_profileEpoch != widget.store.profileEpoch ||
        handoff?.cancelled == true) {
      handoff?.fail(l10n.playerHandoffUserChanged);
      if (handoff != null)
        unawaited(widget.repository.release(handoff.plan.session));
      _playback.fail(message: l10n.playerHandoffCancelled, localFailure: false);
    } else {
      _play(
        _playback.index,
        position: widget.initialPosition,
        handoffPlan: handoff?.plan,
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closed) {
        widget.repository.catalogUpdates.publish(
          widget.repository.catalogUpdates.current(widget.detail.drama),
          retryCover: true,
        );
      }
    });
  }

  void _progressChanged() {
    if (mounted && !_closed) setState(() {});
  }

  void _playbackChanged() {
    if (mounted && !_closed) setState(() {});
  }

  void _prefsChanged() {
    if (mounted && !_closed) setState(() {});
  }

  void _accessChanged() {
    if (!_closed &&
        (widget.store.profileEpoch != _profileEpoch || widget.store.locked)) {
      _preloader.clear();
      _enhancement.suspend();
      _handoffOwned = false;
      _playIntent = false;
      widget.handoff?.fail(l10n.playerHandoffUserChangedShort);
      unawaited(_player.pause());
    }
    if (!_closed &&
        (widget.store.profileEpoch != _profileEpoch ||
            widget.store.locked ||
            !widget.store.allowsSource('hongguo'))) {
      _danmaku.setPlan(null);
    }
  }

  void _configurePictureInPicture() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _pictureInPictureHandlerInstalled = true;
    AppDevice.channel.setMethodCallHandler((call) async {
      if (call.method == 'pictureInPictureChanged') {
        final arguments = call.arguments;
        final active = arguments is Map && arguments['active'] == true;
        _setPictureInPictureStatus(active: active, delayHiddenPause: !active);
      }
    });
    unawaited(_refreshPictureInPictureStatus());
  }

  Future<void> _refreshPictureInPictureStatus() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'pictureInPictureStatus',
      );
      if (!mounted || _closed) return;
      _setPictureInPictureStatus(
        supported: status?['supported'] == true,
        active: status?['active'] == true,
      );
    } on PlatformException {
      if (mounted && !_closed) {
        _setPictureInPictureStatus(supported: false, active: false);
      }
    } on MissingPluginException {
      if (mounted && !_closed) {
        _setPictureInPictureStatus(supported: false, active: false);
      }
    }
  }

  void _setPictureInPictureStatus({
    bool? supported,
    bool? active,
    bool? requested,
    bool delayHiddenPause = false,
  }) {
    final nextSupported = supported ?? _pictureInPictureSupported;
    final nextActive = active ?? _pictureInPictureActive;
    final nextRequested =
        requested ?? (nextActive ? false : _pictureInPictureRequested);
    void assign() {
      _pictureInPictureSupported = nextSupported;
      _pictureInPictureActive = nextActive;
      _pictureInPictureRequested = nextRequested;
    }

    if (mounted && !_closed) {
      setState(assign);
    } else {
      assign();
    }
    if (_pictureInPictureVisible ||
        _lifecycleState == AppLifecycleState.resumed) {
      _pictureInPictureExitTimer?.cancel();
      _applyLifecycleVisibility(pauseWhenHidden: false);
      return;
    }
    _pictureInPictureExitTimer?.cancel();
    _applyLifecycleVisibility(pauseWhenHidden: !delayHiddenPause);
    if (delayHiddenPause) {
      _pictureInPictureExitTimer = Timer(const Duration(milliseconds: 700), () {
        if (!_closed &&
            !_pictureInPictureVisible &&
            _lifecycleState != AppLifecycleState.resumed) {
          _applyLifecycleVisibility();
        }
      });
    }
  }

  void _applyLifecycleVisibility({bool pauseWhenHidden = true}) {
    final visible =
        _lifecycleState == AppLifecycleState.resumed ||
        _pictureInPictureVisible;
    _foreground = visible;
    _enhancement.setForeground(_foreground);
    _syncDanmaku();
    _syncPreload();
    _health.reset();
    if (!visible) _interactions.cancel();
    if (pauseWhenHidden &&
        !visible &&
        (_lifecycleState == AppLifecycleState.paused ||
            _lifecycleState == AppLifecycleState.inactive ||
            _lifecycleState == AppLifecycleState.hidden)) {
      _playIntent = false;
      unawaited(_player.pause());
      unawaited(_saveProgress(flush: true));
    }
    if (visible && _pendingError) {
      _queueRecovery();
    }
  }

  Future<void> _enterPictureInPicture() async {
    if (!_canUsePictureInPicture ||
        _closed ||
        _playback.loading ||
        _playback.error != null ||
        _panelOpen) {
      return;
    }
    _interactions.cancel();
    final rawRatio = _aspectRatio.isFinite && _aspectRatio > 0
        ? _aspectRatio
        : 16 / 9;
    final ratio = rawRatio.clamp(1 / 2.39, 2.39).toDouble();
    final width = ratio >= 1 ? (1000 * ratio).round() : 1000;
    final height = ratio >= 1 ? 1000 : (1000 / ratio).round();
    _setPictureInPictureStatus(requested: true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _closed) return;
    final sourceRect = _pictureInPictureSourceRect();
    final arguments = <String, int>{'width': width, 'height': height};
    if (sourceRect != null) arguments.addAll(sourceRect);
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'enterPictureInPicture',
        arguments,
      );
      if (!mounted || _closed) return;
      final supported = status?['supported'] == true;
      final active = status?['active'] == true;
      final requested = status?['requested'] == true;
      _setPictureInPictureStatus(
        supported: supported,
        active: active,
        requested: requested && !active,
      );
      if (!supported || (!active && !requested)) {
        _notice(l10n.playerDevicePipUnsupported);
      } else if (requested && !active) {
        _pictureInPictureExitTimer?.cancel();
        _pictureInPictureExitTimer = Timer(const Duration(seconds: 2), () {
          if (!_closed &&
              _pictureInPictureRequested &&
              !_pictureInPictureActive) {
            _setPictureInPictureStatus(requested: false);
          }
        });
      }
    } on PlatformException {
      _setPictureInPictureStatus(requested: false);
      _notice(l10n.playerPipEnterFailed);
    } on MissingPluginException {
      _setPictureInPictureStatus(supported: false, requested: false);
      _notice(l10n.playerPipUnsupported);
    }
  }

  Map<String, int>? _pictureInPictureSourceRect() {
    final paneContext = _videoPaneKey.currentContext;
    final renderObject = paneContext?.findRenderObject();
    if (paneContext == null ||
        renderObject is! RenderBox ||
        !renderObject.hasSize) {
      return null;
    }
    final topLeft = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    final ratio =
        MediaQuery.maybeOf(paneContext)?.devicePixelRatio ??
        View.of(paneContext).devicePixelRatio;
    final left = (topLeft.dx * ratio).round().clamp(0, 100000);
    final top = (topLeft.dy * ratio).round().clamp(0, 100000);
    final right = ((topLeft.dx + size.width) * ratio).round().clamp(0, 100000);
    final bottom = ((topLeft.dy + size.height) * ratio).round().clamp(
      0,
      100000,
    );
    if (right <= left || bottom <= top) return null;
    return {'left': left, 'top': top, 'right': right, 'bottom': bottom};
  }

  void _attachLanPlayback() {
    LanController.current?.attachPlayback(
      LanPlaybackHost(
        identity: _lanIdentity,
        title:
            widget.detail.drama.title +
            l10n.playerEpisodePrefix +
            widget.detail.episodes[_playback.index].number.toString() +
            l10n.playerEpisodeSuffix,
        stop: _stopForLan,
      ),
    );
  }

  void _acknowledgeHandoff() {
    final handoff = widget.handoff;
    if (!_handoffOwned ||
        handoff == null ||
        handoff.cancelled ||
        handoff.started.isCompleted ||
        _closed ||
        _playback.loading ||
        _playback.error != null ||
        _progress.openedIndex != _playback.index ||
        _playback.index != widget.initialIndex ||
        widget.store.profileEpoch != _profileEpoch)
      return;
    final state = _player.state;
    final position = state.position.inMilliseconds / 1000;
    final duration = state.duration.inMilliseconds / 1000;
    if (duration > 0 && handoff.position > duration + 2) {
      handoff.fail(l10n.playerResumeTooLong);
      return;
    }
    if (!state.playing ||
        state.buffering ||
        (state.width ?? 0) <= 0 ||
        position < handoff.position - .5 ||
        position > handoff.position + 20)
      return;
    _lanFirstPosition ??= position;
    if (position >= _lanFirstPosition! + .15) handoff.acknowledge(position);
  }

  Future<void> _stopForLan() async {
    final generation = _playback.generation;
    await _serialize(() async {
      if (_closed ||
          generation != _playback.generation ||
          widget.store.profileEpoch != _profileEpoch)
        return;
      _playIntent = false;
      _interactions.cancel();
      _enhancement.suspend();
      _health.reset();
      await _player.pause();
      await _saveProgress(flush: true);
    });
  }

  Future<void> _pushToDevice() async {
    final link = LanController.current;
    if (link == null ||
        _panelOpen ||
        _closed ||
        _playback.loading ||
        _playback.error != null ||
        widget.mediaId != null)
      return;
    final generation = _playback.generation;
    final index = _playback.index;
    bool current() =>
        mounted &&
        !_closed &&
        generation == _playback.generation &&
        index == _playback.index &&
        widget.store.profileEpoch == _profileEpoch;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    try {
      await showLanPush(
        context,
        link,
        snapshot: () => LanPlaybackIntent(
          drama: widget.detail.drama,
          episodeID: widget.detail.episodes[index].id,
          episode: widget.detail.episodes[index].number,
          position: _currentPosition,
        ),
        stillCurrent: current,
        onAccepted: () async {
          if (!current()) throw StateError(l10n.playerContentChanged);
          await _stopForLan();
          if (!current()) throw StateError(l10n.playerContentChanged);
        },
      );
    } catch (error) {
      if (mounted && !_closed) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
  }

  void _syncPreload() {
    if (_closed) return;
    if (!_prefs.preloadEnabled ||
        !_foreground ||
        widget.localOnly ||
        _playback.plan?.local == true ||
        _playback.loading ||
        _playback.error != null ||
        _progress.openedIndex != _playback.index ||
        widget.store.profileEpoch != _profileEpoch ||
        widget.store.locked ||
        _playback.index + 1 >= widget.detail.episodes.length) {
      _preloader.clear();
      return;
    }
    final state = _player.state;
    if (!state.playing || state.buffering || !_playIntent) {
      _preloader.pause();
      return;
    }
    final duration = state.duration.inMilliseconds;
    final position = state.position.inMilliseconds;
    if (duration <= 0 ||
        position < 2000 ||
        (position < duration ~/ 2 && duration - position > 45000) ||
        state.buffer.inMilliseconds - position < 5000) {
      return;
    }
    _preloader.prepare(
      widget.detail.drama,
      widget.detail.episodes[_playback.index + 1],
      quality: _playback.requestedQuality,
    );
  }

  void _syncDanmaku({bool discontinuity = false}) {
    if (_closed) return;
    final state = _player.state;
    _danmaku.update(
      position: state.position,
      duration: state.duration,
      speed: state.rate,
      playing: state.playing && _playIntent && !state.completed,
      buffering: state.buffering,
      foreground: _foreground,
      available:
          !_playback.loading &&
          _playback.error == null &&
          _progress.openedIndex == _playback.index &&
          widget.store.profileEpoch == _profileEpoch &&
          !widget.store.locked &&
          widget.store.allowsSource('hongguo'),
      discontinuity: discontinuity,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final television = AppLayout.isTelevision(context);
    if (_television != television) {
      _fullscreen = false;
      _automaticFullscreenSuppressed = false;
      _interactions.cancel();
    }
    _television = television;
    _orientationController = AppOrientationScope.maybeOf(context);
    final orientation = MediaQuery.orientationOf(context);
    if (_lastOrientation != null && _lastOrientation != orientation) {
      _automaticFullscreenSuppressed = false;
      _interactions.cancel();
    }
    _lastOrientation = orientation;
    _scheduleSystemUi();
  }

  void _scheduleSystemUi() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closed || (!_mobile && !_television)) return;
      final fullscreen = _showFullscreen;
      if (_systemFullscreen == fullscreen) return;
      _systemFullscreen = fullscreen;
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        ),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _applyLifecycleVisibility();
  }

  void _queueRecovery() {
    if (_closed || !_acceptErrors || _playback.error != null) {
      return;
    }
    _pendingError = true;
    if (!_foreground || (_errorTimer?.isActive ?? false)) {
      return;
    }
    final ticket = _playback.generation;
    final position = _player.state.position;
    _errorTimer = Timer(const Duration(milliseconds: 900), () {
      if (_closed ||
          ticket != _playback.generation ||
          !_foreground ||
          !_acceptErrors) {
        return;
      }
      _pendingError = false;
      final state = _player.state;
      if (state.playing &&
          !state.buffering &&
          (state.width ?? 0) > 0 &&
          state.position > position + const Duration(milliseconds: 300)) {
        return;
      }
      unawaited(_recover());
    });
  }

  Future<void> _recover() async {
    final current = _playback.plan;
    if (_closed ||
        !_acceptErrors ||
        !_foreground ||
        current == null ||
        _playback.error != null) {
      return;
    }
    _acceptErrors = false;
    _danmaku.setPlan(null);
    _errorTimer?.cancel();
    _pendingError = false;
    final position = _currentPosition;
    final action = current.local
        ? PlaybackRecoveryAction.stop
        : _recovery.next(current);
    if (action == PlaybackRecoveryAction.stop) {
      _progress.setResumePosition(position);
      final ticket = _playback.generation;
      try {
        await _serialize(() async {
          if (_closed || ticket != _playback.generation) {
            return;
          }
          try {
            await _saveProgress();
            _progress.close();
            await _player.stop();
          } finally {
            await widget.repository.release(current.session);
          }
        });
      } catch (_) {}
      if (mounted && !_closed && ticket == _playback.generation) {
        _playback.fail(
          localFailure: current.local,
          message: current.local
              ? widget.allowOnlineFallback
                    ? l10n.playerLocalVideoFailed
                    : l10n.playerLocalProductFailed
              : l10n.playerRecoveryFailed,
        );
      }
      return;
    }
    await _play(_playback.index, position: position, recoveryAction: action);
  }

  void _togglePlayback() {
    if (_closed || _playback.loading || _playback.error != null) return;
    _handoffOwned = false;
    widget.handoff?.fail(l10n.playerHandoffOperated);
    _interactions.cancel();
    _playIntent = !_player.state.playing;
    if (_playIntent) _enhancement.mediaReady();
    _health.reset();
    if (_playIntent && _player.state.completed) {
      unawaited(_play(_playback.index));
      return;
    }
    unawaited(_player.playOrPause());
    if (!_playIntent) unawaited(_saveProgress(flush: true));
    _syncDanmaku();
  }

  Future<void> _saveProgress({bool flush = false}) => _progress.save(
    position: _player.state.position,
    duration: _player.state.duration,
    flush: flush,
  );

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.catchError((Object _) {}).then((_) => operation());
    _operations = next;
    return next;
  }

  Future<void> _play(
    int index, {
    double position = 0,
    PlaybackRecoveryAction? recoveryAction,
    bool playWhenReady = true,
    PlaybackPlan? handoffPlan,
    bool showControlsOnReady = true,
  }) async {
    if (_closed ||
        widget.store.profileEpoch != _profileEpoch ||
        index < 0 ||
        index >= widget.detail.episodes.length) {
      return;
    }
    _interactions.cancel();
    if (widget.handoff != null &&
        handoffPlan == null &&
        recoveryAction == null) {
      _handoffOwned = false;
      widget.handoff?.fail(l10n.playerHandoffChanged);
    }
    final ticket = _playback.begin(
      index: index,
      message: switch (recoveryAction) {
        PlaybackRecoveryAction.alternative => l10n.playerSwitchingRoute,
        PlaybackRecoveryAction.refresh => l10n.playerRefreshingUrl,
        _ => l10n.playerPreparing,
      },
      showControlsOnReady: showControlsOnReady,
    );
    final warmed =
        handoffPlan ??
        (recoveryAction == null && _prefs.preloadEnabled && !widget.localOnly
            ? _preloader.take(
                widget.detail.drama,
                widget.detail.episodes[index],
                quality: _playback.requestedQuality,
                online: _playback.forceOnline,
              )
            : null);
    _preloader.clear();
    _enhancement.suspend();
    _seekSequence++;
    _danmaku.setPlan(null);
    _acceptErrors = false;
    _pendingError = false;
    _errorTimer?.cancel();
    _health.reset();
    if (recoveryAction == null) {
      _recovery.reset();
      _playIntent = playWhenReady;
    }
    _progress.setResumePosition(position);
    LanController.current?.detachPlayback(_lanIdentity);
    _lanIdentity = Object();
    _attachLanPlayback();
    PlaybackPlan? prepared;
    PlaybackPlan? retained;
    bool installed = false;
    try {
      await _serialize(() async {
        if (_closed || ticket != _playback.generation) {
          return;
        }
        await _saveProgress(flush: true);
        await _enhancement.beforeMedia();
        if (_closed || ticket != _playback.generation) return;
        _progress.close();
        await _player.stop();
        final previous = _playback.plan;
        _playback.setPlan(null);
        if (recoveryAction == PlaybackRecoveryAction.alternative) {
          retained = previous;
        } else if (previous != null) {
          await widget.repository.release(previous.session);
        }
      });
      if (_closed || ticket != _playback.generation) {
        return;
      }
      prepared = retained != null
          ? await _loader.fallback(retained!)
          : warmed != null
          ? await _loader.use(warmed)
          : await _loader.load(
              widget.detail.drama,
              widget.detail.episodes[index],
              quality: _playback.requestedQuality,
              localOnly: widget.localOnly,
              online: _playback.forceOnline,
            );
      if (prepared == null) {
        return;
      }
      final plan = prepared;
      await _serialize(() async {
        if (_closed || ticket != _playback.generation) {
          await widget.repository.release(plan.session);
          return;
        }
        if (plan.url.isEmpty) {
          throw AppFailure(l10n.playerNoUrl);
        }
        final platform = _player.platform;
        if (platform is NativePlayer) {
          await platform.setProperty(
            'demuxer-lavf-o',
            [
              'seg_max_retry=3',
              'strict=experimental',
              'allowed_extensions=ALL',
              plan.local
                  ? 'protocol_whitelist=[file,crypto,data]'
                  : 'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
              if (plan.decryptionKey.isNotEmpty)
                'decryption_key=${plan.decryptionKey}',
            ].join(','),
          );
          await platform.setProperty('network-timeout', '20');
        }
        _playback.setPlan(plan);
        installed = true;
        _acceptErrors = true;
        await _player.open(
          Media(
            plan.url,
            httpHeaders: plan.headers,
            start: position > 0
                ? Duration(milliseconds: (position * 1000).round())
                : null,
          ),
          play: _foreground && _playIntent,
        );
        if (_closed || ticket != _playback.generation) {
          return;
        }
        _progress.markOpened(index);
        _enhancement.mediaReady();
        _attachLanPlayback();
        _health.reset();
        await _interactions.applySpeed();
        if (mounted && !_closed && ticket == _playback.generation) {
          _playback.finish(plan: plan, index: index);
          _danmaku.setPlan(plan);
          _syncDanmaku();
          _acknowledgeHandoff();
          _menuRevision.value++;
        }
      });
    } catch (error) {
      if (!_closed && mounted && ticket == _playback.generation) {
        if (prepared != null && identical(_playback.plan, prepared)) {
          _acceptErrors = true;
          _queueRecovery();
        } else {
          if (prepared != null) {
            await widget.repository.release(prepared.session);
          }
          if (mounted && !_closed && ticket == _playback.generation) {
            final message = error is AppFailure
                ? error.message
                : l10n.playerPlayFailed;
            _playback.fail(
              message: message,
              localFailure:
                  (error is AppFailure && error.code == 'local_media') ||
                  (widget.localOnly && !_playback.forceOnline),
            );
            widget.handoff?.fail(message);
          }
        }
      } else if (prepared != null && !installed) {
        await widget.repository.release(prepared.session);
      }
    } finally {
      if (warmed != null && !installed) {
        await widget.repository.release(warmed.session);
      }
      if (retained != null) {
        await widget.repository.release(retained!.session);
      }
    }
  }

  Future<void> _switchOnline() async {
    _playback.setForceOnline(true);
    await _retry();
  }

  Future<void> _retry({int? quality}) async {
    final position = _currentPosition;
    if (quality != null) {
      _playback.setRequestedQuality(quality);
    }
    await _play(
      _playback.index,
      position: position,
      playWhenReady:
          quality == null || _playback.error != null || _player.state.playing,
    );
  }

  bool get _showFullscreen =>
      _television ||
      _fullscreen ||
      (_mobile &&
          !_automaticFullscreenSuppressed &&
          _aspectRatio >= 1 &&
          MediaQuery.orientationOf(context) == Orientation.landscape);

  Future<void> _rotate() async {
    if (_rotating || _television) {
      return;
    }
    final fullscreen = !_showFullscreen;
    final previous = _fullscreen;
    final previousSuppressed = _automaticFullscreenSuppressed;
    _interactions.cancel();
    _rotating = true;
    setState(() {
      _fullscreen = fullscreen;
      _automaticFullscreenSuppressed = !fullscreen;
    });
    try {
      if (Platform.isWindows) {
        await windowManager.setFullScreen(fullscreen);
      } else if (_mobile) {
        await (_orientationController?.setPlayback(
              this,
              fullscreen: fullscreen,
              aspectRatio: _aspectRatio,
            ) ??
            SystemChrome.setPreferredOrientations(
              AppOrientationController.orientations(
                television: _television,
                fullscreen: fullscreen,
                aspectRatio: _aspectRatio,
              ),
            ));
      }
    } catch (_) {
      if (mounted && !_closed) {
        setState(() {
          _fullscreen = previous;
          _automaticFullscreenSuppressed = previousSuppressed;
        });
        _notice(l10n.playerFullscreenFailed);
      }
    } finally {
      _rotating = false;
      if (mounted && !_closed) _scheduleSystemUi();
    }
  }

  void _notice(String message) {
    if (!mounted || _closed) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _setPreferences(PlaybackPreferences preferences) async {
    if (_closed || widget.store.profileEpoch != _profileEpoch) {
      throw StateError(l10n.playerUserChanged);
    }
    _interactions.cancel();
    final nextPreferences = preferences.copyWith(
      autoAdvance: true,
      preload: true,
    );
    if (!await _prefs.save(nextPreferences)) return;
    if (!mounted || _closed || widget.store.profileEpoch != _profileEpoch)
      return;
    final qualityChanged =
        nextPreferences.quality != _playback.requestedQuality;
    _enhancement.setPreferences(nextPreferences.enhancement);
    _playback.setRequestedQuality(nextPreferences.quality);
    _danmaku.setEnabled(_prefs.danmakuEnabled);
    _syncDanmaku();
    if (qualityChanged) _preloader.clear();
    _syncPreload();
    _menuRevision.value++;
    await _interactions.applySpeed();
    if (qualityChanged && _playback.plan?.local != true) {
      await _retry(quality: nextPreferences.quality);
    }
  }

  Future<void> _toggleFavorite() async {
    try {
      await widget.store.toggleFavorite(widget.detail.drama);
      if (mounted && !_closed) setState(() {});
    } catch (_) {
      _notice(l10n.playerFollowSaveFailed);
    }
  }

  Future<void> _toggleDanmaku() async {
    if (widget.detail.drama.source != 'hongguo') return;
    try {
      await _setPreferences(
        _preferences.copyWith(danmaku: !_prefs.danmakuEnabled),
      );
    } catch (_) {
      _notice(l10n.playerDanmakuPrefFailed);
    }
  }

  Future<void> _retryDanmakuFromControls() async {
    try {
      _danmaku.retry();
      _menuRevision.value++;
    } catch (_) {
      _notice(l10n.playerDanmakuRetryFailed);
    }
  }

  Future<void> _submitDownloadSelection(DownloadSelection selection) async {
    if (!widget.repository.supportsDownloads ||
        !widget.store.canDownload ||
        widget.store.profileEpoch != _profileEpoch ||
        widget.mediaId != null) {
      return;
    }
    final added = await widget.repository.enqueueDownloads(
      widget.detail,
      selection.episodes,
      quality: selection.quality,
    );
    if (!mounted || _closed) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added == 0 ? l10n.detailAlreadyQueued : l10n.detailAdded(added),
        ),
        action: SnackBarAction(
          label: l10n.detailView,
          onPressed: () => context.push(AppRoutes.downloads),
        ),
      ),
    );
  }

  Future<void> _openPanel(PlayerMenuSection section) async {
    if (_panelOpen || _closed) return;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    final menuTheme = _showFullscreen ? AppTheme.dark : Theme.of(context);
    try {
      final index = await showDialog<int>(
        context: context,
        builder: (menuContext) => AnimatedBuilder(
          animation: Listenable.merge([
            _menuRevision,
            widget.store,
            _danmaku,
            _preloader,
          ]),
          builder: (_, _) => Theme(
            data: menuTheme,
            child: PlayerMenu(
              section: section,
              episodes: widget.detail.episodes,
              currentIndex: _playback.index,
              preferences: _preferences,
              qualities: _playback.plan?.qualities ?? [],
              actualQuality: _playback.plan?.quality ?? 0,
              local: _playback.plan?.local == true,
              favorite: widget.store.isFavorite(widget.detail.drama.id),
              mobile: _mobile,
              onEpisode: (index) => Navigator.pop(menuContext, index),
              onPreferences: _setPreferences,
              showDanmaku: widget.detail.drama.source == 'hongguo',
              danmakuStatus: _danmaku.status,
              onRetryDanmaku: _danmaku.canRetry ? _danmaku.retry : null,
              preloadStatus: _preloader.status,
              enhancement: _enhancementForUi,
              onCompareEnhancement: () {
                unawaited(_enhancement.toggleCompare());
                Navigator.pop(menuContext);
              },
              onFavorite: () =>
                  widget.store.toggleFavorite(widget.detail.drama),
            ),
          ),
        ),
      );
      if (mounted && !_closed && index != null && index != _playback.index) {
        await _play(index);
      }
    } finally {
      if (mounted && !_closed) {
        setState(() => _panelOpen = false);
        _playerFocus.requestFocus();
      }
    }
  }

  Future<void> _seekTo(Duration target) async {
    if (_closed || _playback.loading || _playback.error != null) return;
    _handoffOwned = false;
    widget.handoff?.fail(l10n.playerHandoffSeeked);
    final ticket = ++_seekSequence;
    final generation = _playback.generation;
    _danmaku.beginSeek();
    _enhancement.ignorePerformance();
    var succeeded = false;
    try {
      await _player.seek(target);
      succeeded = true;
    } catch (_) {
      _notice(l10n.playerJumpFailed);
    } finally {
      if (!_closed &&
          ticket == _seekSequence &&
          generation == _playback.generation) {
        _danmaku.endSeek(succeeded ? target : _player.state.position);
      }
    }
  }

  void _seek(int seconds) {
    final desired = _player.state.position + Duration(seconds: seconds);
    final maxDuration = _player.state.duration;
    final target = desired < Duration.zero
        ? Duration.zero
        : maxDuration > Duration.zero && desired > maxDuration
        ? maxDuration
        : desired;
    unawaited(_seekTo(target));
  }

  Future<void> _televisionEpisodes(BuildContext context) async {
    if (_panelOpen || _closed) return;
    setState(() => _panelOpen = true);
    int? index;
    try {
      index = await showDialog<int>(
        context: context,
        builder: (_) => Theme(
          data: televisionTheme(AppTheme.dark),
          child: TelevisionEpisodeDialog(
            episodes: widget.detail.episodes,
            currentIndex: _playback.index,
          ),
        ),
      );
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
    if (index != null && mounted && !_closed && index != _playback.index) {
      await _play(index);
    }
  }

  Future<void> _televisionSettings(BuildContext context) async {
    if (_panelOpen || _closed) return;
    setState(() => _panelOpen = true);
    TelevisionPlaybackSetting? selection;
    try {
      selection = await showDialog<TelevisionPlaybackSetting>(
        context: context,
        builder: (menuContext) => AnimatedBuilder(
          animation: Listenable.merge([_danmaku, _preloader]),
          builder: (_, _) => Theme(
            data: televisionTheme(AppTheme.dark),
            child: TelevisionSettingsDialog(
              speed: _prefs.speed,
              quality: _playback.requestedQuality,
              qualities: _playback.plan?.qualities ?? [],
              favorite: widget.store.isFavorite(widget.detail.drama.id),
              onFavorite: _toggleFavorite,
              autoAdvance: _prefs.autoAdvance,
              danmaku: _prefs.danmakuEnabled,
              showDanmaku: widget.detail.drama.source == 'hongguo',
              danmakuStatus: _danmaku.status,
              onRetryDanmaku: _danmaku.canRetry ? _danmaku.retry : null,
              preload: _prefs.preloadEnabled,
              preloadStatus: _preloader.status,
              enhancement: _enhancementForUi,
              onCompareEnhancement: () {
                unawaited(_enhancement.toggleCompare());
                Navigator.pop(menuContext);
              },
            ),
          ),
        ),
      );
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
    if (selection == null || !mounted || _closed) return;
    try {
      await _setPreferences(
        _preferences.copyWith(
          speed: selection.speed,
          quality: selection.quality,
          autoAdvance: true,
          danmaku: selection.danmaku,
          preload: true,
          enhancement: selection.enhancement,
        ),
      );
    } catch (_) {
      _notice(l10n.playerPrefFailed);
    }
  }

  void _back() {
    if (_showFullscreen && !_television) {
      _rotate();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _progress.removeListener(_progressChanged);
    _playback.removeListener(_playbackChanged);
    _prefs.removeListener(_prefsChanged);
    final enhancementClosed = _enhancement.close();
    LanController.current?.detachPlayback(_lanIdentity);
    widget.handoff?.fail(l10n.playerHandoffExited);
    widget.store.removeListener(_accessChanged);
    _danmaku.dispose();
    _preloader.dispose();
    _playback.invalidate();
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _healthTimer?.cancel();
    _errorTimer?.cancel();
    _pictureInPictureExitTimer?.cancel();
    if (_pictureInPictureHandlerInstalled) {
      AppDevice.channel.setMethodCallHandler(null);
    }
    _interactions.dispose();
    _playerFocus.dispose();
    _menuRevision.dispose();
    unawaited(_saveProgress(flush: true));
    _progress.dispose();
    _playback.dispose();
    _prefs.dispose();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    unawaited(widget.repository.release(_session));
    unawaited(_loader.close().catchError((Object _) {}));
    unawaited(
      _operations.catchError((Object _) {}).then((_) async {
        await _interactions.pendingRates.catchError((Object _) {});
        await enhancementClosed.catchError((Object _) {});
        await _player.dispose();
      }),
    );
    if (Platform.isWindows) {
      unawaited(windowManager.setFullScreen(false));
    } else if (_mobile || _television && Platform.isAndroid) {
      unawaited(
        (_orientationController?.releasePlayback(this) ??
                SystemChrome.setPreferredOrientations(
                  AppOrientationController.orientations(
                    television: _television,
                  ),
                ))
            .catchError((Object _) {}),
      );
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  String _followStatusLabel(FollowStatus status) => switch (status) {
    FollowStatus.planned => l10n.followPlanned,
    FollowStatus.watching => l10n.followWatching,
    FollowStatus.watched => l10n.followWatched,
  };

  @override
  Widget build(BuildContext context) {
    final inherited = Theme.of(context);
    final theme = _television ? televisionTheme(inherited) : inherited;
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) {
          final fullscreen = _showFullscreen;
          final overlayBrightness = fullscreen
              ? Brightness.dark
              : Theme.of(context).brightness;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: AppTheme.systemBars(overlayBrightness),
            child: _buildPlayer(context),
          );
        },
      ),
    );
  }

  Widget _buildPlayer(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.detail.drama.title;
    final fullscreen = _showFullscreen;
    final pictureInPicture = _pictureInPictureVisible;
    return PopScope(
      canPop: _television || !fullscreen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && fullscreen && !_television) {
          _rotate();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _back,
          const SingleActivator(LogicalKeyboardKey.goBack): _back,
        },
        child: Focus(
          focusNode: _playerFocus,
          onKeyEvent: (_, event) {
            if (_television ||
                _panelOpen ||
                !_playerFocus.hasPrimaryFocus ||
                !(ModalRoute.of(context)?.isCurrent ?? true)) {
              return KeyEventResult.ignored;
            }
            return _interactions.key(event);
          },
          autofocus: !_television,
          canRequestFocus: !_television,
          skipTraversal: _television,
          child: Scaffold(
            backgroundColor: fullscreen || pictureInPicture
                ? Colors.black
                : theme.scaffoldBackgroundColor,
            appBar: pictureInPicture || fullscreen || _mobile
                ? null
                : AppBar(
                    title: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    actions: [
                      IconButton(
                        tooltip: l10n.rotateFullscreen,
                        onPressed: _rotate,
                        icon: const Icon(Icons.screen_rotation_alt_rounded),
                      ),
                    ],
                  ),
            body: pictureInPicture
                ? _videoPane(context)
                : SafeArea(
                    top: !_television && (fullscreen || _mobile),
                    bottom: !fullscreen,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final desktop = constraints.maxWidth >= 840;
                        if (fullscreen) {
                          return _videoPane(context);
                        }
                        if (desktop ||
                            constraints.maxWidth >
                                constraints.maxHeight * 1.3) {
                          return Row(
                            children: [
                              Expanded(
                                child: Column(
                                  children: [
                                    Expanded(child: _videoPane(context)),
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: desktop ? 312 : 210,
                                child: _episodePanel(),
                              ),
                            ],
                          );
                        }
                        if (_mobile) {
                          final height = (constraints.maxWidth / _aspectRatio)
                              .clamp(0.0, constraints.maxHeight * .56);
                          return Column(
                            children: [
                              SizedBox(
                                height: height,
                                width: double.infinity,
                                child: _videoPane(context),
                              ),
                              Expanded(child: _mobilePlaybackPanel()),
                            ],
                          );
                        }
                        final height = (constraints.maxWidth / _aspectRatio)
                            .clamp(0.0, constraints.maxHeight * .64);
                        return Column(
                          children: [
                            SizedBox(
                              height: height,
                              width: double.infinity,
                              child: _videoPane(context),
                            ),
                            Expanded(child: _episodePanel()),
                          ],
                        );
                      },
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _videoPane(BuildContext context) {
    final videoTheme = _television
        ? televisionTheme(AppTheme.dark)
        : AppTheme.dark;
    final title =
        '${widget.detail.drama.title}'
        '${l10n.playerEpisodePrefix}'
        '${widget.detail.episodes[_playback.index].number}'
        '${l10n.playerEpisodeSuffix}'
        '${_playback.plan?.local == true ? l10n.playerLocalSuffix : ''}'
        '${widget.detail.episodes[_playback.index].vip ? l10n.playerVipTrial : ''}'
        '${(_playback.plan?.routeIndex ?? 0) > 0 ? l10n.playerRouteSuffix(_playback.plan!.routeIndex + 1) : ''}';
    final hideOverlayForPictureInPicture = _pictureInPictureVisible;
    final Widget controls = hideOverlayForPictureInPicture
        ? const SizedBox.shrink()
        : _television
        ? TelevisionControls(
            player: _player,
            title: title,
            enabled: !_playback.loading && _playback.error == null,
            showOnPlaybackReady: _playback.showControlsOnPlaybackReady,
            enhancement: _enhancementForUi,
            onTogglePlayback: _togglePlayback,
            onSeek: _seek,
            onPrevious: _playback.index > 0
                ? () => _play(_playback.index - 1)
                : null,
            onNext: _playback.index + 1 < widget.detail.episodes.length
                ? () => _play(_playback.index + 1)
                : null,
            onEpisodes: () => _televisionEpisodes(context),
            onSettings: () => _televisionSettings(context),
            onBack: _back,
          )
        : PlayerControls(
            player: _player,
            interactions: _interactions,
            enabled: !_playback.loading && _playback.error == null,
            enhancement: _enhancementForUi,
            panelOpen: _panelOpen,
            fullscreen: _showFullscreen,
            showOnPlaybackReady: _playback.showControlsOnPlaybackReady,
            title: title,
            onTogglePlayback: _togglePlayback,
            swipeEnabled: _mobile,
            onFullscreen: _rotate,
            onBack: _back,
            onFocusSurface: _playerFocus.requestFocus,
            onSeek: _seekTo,
            speed: _prefs.speed,
            qualityLabel: _qualityLabel,
            showDanmaku: widget.detail.drama.source == 'hongguo',
            danmakuEnabled: _prefs.danmakuEnabled,
            danmakuStatus: _danmaku.status,
            onEpisodes: () => _openPanel(PlayerMenuSection.episodes),
            onSpeed: () => _openPanel(PlayerMenuSection.speed),
            onQuality: () => _openPanel(PlayerMenuSection.quality),
            onDanmaku: widget.detail.drama.source == 'hongguo'
                ? _toggleDanmaku
                : null,
            onRetryDanmaku: _danmaku.canRetry
                ? _retryDanmakuFromControls
                : null,
            onPush: widget.mediaId == null ? _pushToDevice : null,
            onPictureInPicture: _canUsePictureInPicture
                ? _enterPictureInPicture
                : null,
            onPrevious: _playback.index > 0
                ? () => _play(_playback.index - 1)
                : null,
            onNext: _playback.index + 1 < widget.detail.episodes.length
                ? () => _play(_playback.index + 1)
                : null,
          );
    final layeredControls = Stack(
      fit: StackFit.expand,
      children: [
        if (!hideOverlayForPictureInPicture)
          DanmakuOverlay(controller: _danmaku, aspectRatio: _aspectRatio),
        controls,
      ],
    );
    return Theme(
      data: videoTheme,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final ratio = MediaQuery.devicePixelRatioOf(context);
          final pixels = Size(
            constraints.maxWidth * ratio,
            constraints.maxHeight * ratio,
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_closed) {
              _enhancement.setViewport(pixels, television: _television);
            }
          });
          return Stack(
            key: _videoPaneKey,
            fit: StackFit.expand,
            children: [
              if (widget.videoBuilder != null)
                widget.videoBuilder!(layeredControls)
              else
                Video(
                  controller: _video!,
                  fit: BoxFit.contain,
                  controls: (_) => layeredControls,
                ),
              if (_playback.loading && !hideOverlayForPictureInPicture)
                ColoredBox(
                  color: Colors.black.withValues(alpha: .78),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(_playback.loadingMessage),
                      ],
                    ),
                  ),
                ),
              if (_playback.error != null && !hideOverlayForPictureInPicture)
                ColoredBox(
                  color: Colors.black.withValues(alpha: .9),
                  child: StatusPanel(
                    title: l10n.playerCannotPlay,
                    message: _playback.error!,
                    onRetry: () => _retry(),
                    action: _playback.localFailure
                        ? l10n.playerRetryLocal
                        : l10n.playerRetryPlay,
                    secondaryAction:
                        _playback.localFailure && widget.allowOnlineFallback
                        ? TextButton.icon(
                            onPressed: _switchOnline,
                            icon: const Icon(Icons.cloud_outlined),
                            label: Text(l10n.playerSwitchOnline),
                          )
                        : !_playback.localFailure &&
                              !widget.localOnly &&
                              widget.repository.supportsSourceManagement
                        ? SourceDiagnosticsButton(
                            repository: widget.repository,
                            store: widget.store,
                            drama: widget.detail.drama,
                          )
                        : null,
                    icon: Icons.play_disabled_rounded,
                  ),
                ),
              if ((_playback.loading || _playback.error != null) &&
                  !hideOverlayForPictureInPicture &&
                  _showFullscreen &&
                  !_television)
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: l10n.exitFullscreen,
                          onPressed: _rotate,
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () =>
                              _openPanel(PlayerMenuSection.episodes),
                          child: Text(l10n.episodes),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_progress.warning != null && !hideOverlayForPictureInPicture)
                Positioned(
                  top: 52,
                  left: 12,
                  right: 12,
                  child: SafeArea(
                    bottom: false,
                    child: Material(
                      color: const Color(0xE6322424),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              _progress.warning!,
                              style: const TextStyle(fontSize: 12),
                            ),
                            TextButton(
                              onPressed: _saveProgress,
                              child: Text(l10n.sourceRetrySave),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _mobilePlaybackPanel() {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            _mobileTabs(colors),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _mobileTab == 0
                      ? _episodePanel(compact: true)
                      : _mobileTab == 1
                      ? _mobileSynopsis()
                      : _mobileDownload(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mobileTabs(ColorScheme colors) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
    child: SizedBox(
      height: 42,
      child: Row(
        children: [
          _mobileTabButton(0, l10n.episodes),
          _mobileTabButton(1, l10n.playerSynopsis),
          _mobileTabButton(2, l10n.playerDownload),
        ],
      ),
    ),
  );

  Widget _mobileTabButton(int value, String label) {
    final selected = _mobileTab == value;
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _mobileTab = value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? colors.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? colors.onSurface : colors.onSurfaceVariant,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _mobileSynopsis() {
    final drama = widget.detail.drama;
    final colors = Theme.of(context).colorScheme;
    final meta = [
      SourceSite.byId(drama.source).name,
      if (drama.episodes > 0) l10n.detailTotalEpisodes(drama.episodes),
      if (drama.releaseStatus.isNotEmpty && drama.releaseStatus != 'unknown')
        drama.releaseLabel,
      if (drama.category.isNotEmpty) drama.category,
    ];
    final body = drama.description.trim().isEmpty
        ? l10n.playerNoSynopsis
        : drama.description;
    return ColoredBox(
      color: colors.surface,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 82,
                height: 123,
                child: DramaCover(drama: drama, repository: widget.repository),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      drama.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        meta.join(' · '),
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                    if (drama.onlineDate.isNotEmpty ||
                        drama.heat.isNotEmpty ||
                        drama.views.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        [
                          if (drama.onlineDate.isNotEmpty)
                            l10n.detailOnlineDate(drama.onlineDate),
                          if (drama.heat.isNotEmpty)
                            l10n.detailHeat(drama.heat),
                          if (drama.views.isNotEmpty)
                            l10n.detailPlayViews(drama.views),
                        ].join(' · '),
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _mobileFollowControl(drama),
          if (drama.tags.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in drama.tags.take(12))
                  Chip(label: Text(tag), visualDensity: VisualDensity.compact),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Text(body, style: const TextStyle(height: 1.55)),
          if (widget.detail.warning.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(widget.detail.warning, style: TextStyle(color: colors.error)),
          ],
        ],
      ),
    );
  }

  Widget _mobileFollowControl(Drama drama) {
    final state = widget.store.following(drama.id);
    return PopupMenuButton<String>(
      key: const ValueKey('player-follow-status'),
      tooltip: l10n.detailFollowStatus,
      onSelected: (value) async {
        if (_profileEpoch != widget.store.profileEpoch) return;
        if (value == 'remove') {
          await saveUserChange(
            context,
            () => widget.store.toggleFavorite(drama),
          );
        } else {
          final status = FollowStatus.values.firstWhere(
            (status) => status.name == value,
          );
          await saveUserChange(
            context,
            () => widget.store.setFollowStatus(drama, status),
          );
        }
        if (mounted && !_closed) setState(() {});
      },
      itemBuilder: (_) => [
        for (final status in FollowStatus.values)
          CheckedPopupMenuItem(
            value: status.name,
            checked: state?.status == status,
            child: Text(_followStatusLabel(status)),
          ),
        if (state != null)
          PopupMenuItem(value: 'remove', child: Text(l10n.detailUnfollow)),
      ],
      child: Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: state == null
              ? Theme.of(context).colorScheme.surfaceContainerHighest
              : Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              state == null
                  ? Icons.bookmark_add_outlined
                  : Icons.bookmark_rounded,
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(state?.label ?? l10n.detailFollow),
            const SizedBox(width: 2),
            const Icon(Icons.expand_more_rounded, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _mobileDownload() {
    final colors = Theme.of(context).colorScheme;
    if (!widget.repository.supportsDownloads || !widget.store.canDownload) {
      return ColoredBox(
        color: colors.surface,
        child: StatusPanel(
          title: l10n.playerDownloadUnavailable,
          message: l10n.playerLocalDownloadUnavailable,
          icon: Icons.download_outlined,
        ),
      );
    }
    return DownloadPicker(
      detail: widget.detail,
      preferences: widget.store.downloadPreferences,
      embedded: true,
      onSubmit: _submitDownloadSelection,
    );
  }

  Widget _episodePanel({bool compact = false}) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: PlayerEpisodeGrid(
      episodes: widget.detail.episodes,
      currentIndex: _playback.index,
      compact: compact,
      title: compact ? l10n.playerEpisodesLabel : l10n.episodes,
      onSelected: (index) => _play(index),
    ),
  );
}
