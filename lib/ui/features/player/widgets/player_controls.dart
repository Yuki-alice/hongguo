import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'package:hoshi/ui/features/player/widgets/player_interactions.dart';
import 'package:hoshi/ui/core/empty_state.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/data/video_enhancement/video_enhancement.dart';

class PlayerControls extends StatefulWidget {
  const PlayerControls({
    super.key,
    required this.player,
    required this.interactions,
    required this.enabled,
    required this.fullscreen,
    required this.showOnPlaybackReady,
    required this.onFullscreen,
    required this.onBack,
    required this.onPrevious,
    required this.onNext,
    required this.title,
    required this.onTogglePlayback,
    required this.onEpisodes,
    required this.onSpeed,
    required this.onQuality,
    required this.speed,
    required this.qualityLabel,
    required this.onFocusSurface,
    this.showDanmaku = false,
    this.danmakuEnabled = false,
    this.danmakuStatus = '',
    this.swipeEnabled = false,
    this.panelOpen = false,
    this.onSeek,
    this.onDanmaku,
    this.onRetryDanmaku,
    this.onPictureInPicture,
    this.enhancement,
    this.favorite = false,
    this.onFavorite,
  });

  final Player player;
  final PlayerInteractions interactions;
  final bool enabled;
  final bool fullscreen;
  final bool showOnPlaybackReady;
  final VoidCallback onFullscreen;
  final VoidCallback onBack;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final String title;
  final VoidCallback onTogglePlayback;
  final Future<void> Function() onEpisodes;
  final Future<void> Function() onSpeed;
  final Future<void> Function() onQuality;
  final double speed;
  final String qualityLabel;
  final VoidCallback onFocusSurface;
  final bool showDanmaku;
  final bool danmakuEnabled;
  final String danmakuStatus;
  final bool swipeEnabled;
  final bool panelOpen;
  final Future<void> Function(Duration)? onSeek;
  final Future<void> Function()? onDanmaku;
  final Future<void> Function()? onRetryDanmaku;
  final Future<void> Function()? onPictureInPicture;
  final VideoEnhancementController? enhancement;
  final bool favorite;
  final VoidCallback? onFavorite;

  @override
  State<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends State<PlayerControls> {
  AppLocalizations get l10n => AppLocalizations.of(context);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _hideTimer;
  bool _visible = true;
  bool _suppressAutoPlaybackStart = false;
  bool _lastPlaying = false;
  double? _seekValue;

  @override
  void initState() {
    super.initState();
    _visible = widget.showOnPlaybackReady;
    _suppressAutoPlaybackStart = !widget.showOnPlaybackReady;
    _lastPlaying = widget.player.state.playing;
    for (final stream in [
      widget.player.stream.position,
      widget.player.stream.duration,
      widget.player.stream.buffer,
      widget.player.stream.playing,
      widget.player.stream.buffering,
      widget.player.stream.volume,
    ]) {
      _subscriptions.add(
        stream.listen((_) {
          if (mounted) setState(() {});
        }),
      );
    }
    _subscriptions.add(
      widget.player.stream.playing.listen((playing) {
        final wasPlaying = _lastPlaying;
        _lastPlaying = playing;
        if (!mounted || !widget.enabled) return;
        if (!playing) {
          _show();
        } else if (!wasPlaying) {
          if (_suppressAutoPlaybackStart) {
            _suppressAutoPlaybackStart = false;
            _scheduleHide();
          } else {
            _show();
          }
        }
      }),
    );
    widget.interactions.addListener(_interactionChanged);
    _scheduleHide();
  }

  @override
  void didUpdateWidget(PlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled ||
        widget.panelOpen != oldWidget.panelOpen ||
        widget.fullscreen != oldWidget.fullscreen ||
        widget.showOnPlaybackReady != oldWidget.showOnPlaybackReady) {
      _seekValue = null;
      if (widget.showOnPlaybackReady) {
        _suppressAutoPlaybackStart = false;
      } else if (widget.enabled && !oldWidget.enabled) {
        _suppressAutoPlaybackStart = !widget.player.state.playing;
      } else if (!widget.enabled && oldWidget.enabled) {
        _suppressAutoPlaybackStart = true;
        _visible = false;
      }
      if (widget.enabled && !oldWidget.enabled) {
        if (widget.showOnPlaybackReady || !widget.player.state.playing) {
          _visible = true;
        } else {
          _visible = false;
        }
      } else if (widget.panelOpen != oldWidget.panelOpen ||
          widget.fullscreen != oldWidget.fullscreen) {
        _visible = true;
      }
      _scheduleHide();
    }
  }

  void _interactionChanged() {
    if (mounted && widget.interactions.feedback.isNotEmpty) _show();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!widget.enabled ||
        widget.panelOpen ||
        !widget.player.state.playing ||
        _seekValue != null) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted &&
          widget.enabled &&
          !widget.panelOpen &&
          widget.player.state.playing &&
          !widget.player.state.buffering &&
          !widget.interactions.boosting &&
          _seekValue == null) {
        setState(() => _visible = false);
      }
    });
  }

  void _show() {
    if (!mounted) return;
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _tap() {
    if (widget.interactions.suppressTap) return;
    widget.onFocusSurface();
    if (widget.swipeEnabled &&
        MediaQuery.orientationOf(context) == Orientation.portrait &&
        widget.enabled) {
      widget.onTogglePlayback();
      _show();
    } else {
      setState(() => _visible = !_visible);
      _scheduleHide();
    }
  }

  Future<void> _panel(Future<void> Function() open) async {
    _hideTimer?.cancel();
    widget.interactions.cancel();
    await open();
    _show();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.interactions.removeListener(_interactionChanged);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.player.state;
    final duration = state.duration.inMilliseconds / 1000;
    final position = state.position.inMilliseconds / 1000;
    final buffered = state.buffer.inMilliseconds / 1000;
    final visible =
        _visible || !state.playing || state.buffering || widget.panelOpen;
    return MouseRegion(
      onHover: (_) => _show(),
      cursor: visible ? SystemMouseCursors.basic : SystemMouseCursors.none,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          fit: StackFit.expand,
          children: [
            Listener(
              key: const ValueKey('player-gesture-surface'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                widget.onFocusSurface();
                widget.interactions.pointerDown(
                  event,
                  swipeEnabled: widget.swipeEnabled,
                  height: constraints.maxHeight,
                );
              },
              onPointerMove: widget.interactions.pointerMove,
              onPointerUp: widget.interactions.pointerUp,
              onPointerCancel: widget.interactions.pointerCancel,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _tap,
                onDoubleTap: () {
                  if (!widget.enabled || widget.interactions.suppressTap) {
                    return;
                  }
                  widget.onTogglePlayback();
                  _show();
                },
              ),
            ),
            if (state.buffering && widget.enabled)
              const IgnorePointer(
                child: Center(child: AppLoadingIndicator(size: 36)),
              ),
            IgnorePointer(
              ignoring: !visible,
              child: ExcludeFocus(
                excluding: !visible,
                child: AnimatedOpacity(
                  opacity: visible ? 1 : 0,
                  duration: Md3Motion.of(context, Md3Motion.standardAccelerate),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 两段式 scrim，与参照应用 `player_item_panel.dart` 的
                      // `_buildScrim` 一致：顶部 50 高、底部 100 高，都用
                      // `Colors.black45`。整屏三段渐变会把画面中段也压暗，
                      // 而中段恰恰是观众要看的地方。
                      const IgnorePointer(
                        child: Column(
                          children: [
                            _Scrim(
                              height: 50,
                              colors: [Colors.black45, Colors.transparent],
                            ),
                            Spacer(),
                            _Scrim(
                              height: 100,
                              colors: [Colors.transparent, Colors.black45],
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          8,
                          _topChromeInset(),
                          8,
                          _bottomChromeInset(),
                        ),
                        child: Stack(
                          children: [
                            _topBar(),
                            _sideDanmakuControl(),
                            _bottomControls(
                              constraints: constraints,
                              volume: state.volume,
                              duration: duration,
                              position: position,
                              buffered: buffered,
                              playing: state.playing,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _gestureFeedback(),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    final compact = widget.swipeEnabled && !widget.fullscreen;
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.only(top: compact ? 8 : 0),
        child: Row(
          children: [
            _overlayIconButton(
              tooltip: widget.fullscreen ? l10n.exitFullscreen : l10n.back,
              onPressed: widget.fullscreen
                  ? widget.onFullscreen
                  : widget.onBack,
              icon: widget.fullscreen
                  ? Icons.arrow_back_rounded
                  : Icons.arrow_back_ios_new_rounded,
            ),
            if (compact)
              const Spacer()
            else
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // 播放页的 DefaultTextStyle 来自浅色 Material，覆盖在黑底上
                  // 会变成深灰；标题固定用白色（参照应用顶栏同款）。
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            if (compact) _compactMoreMenu(),
            if (widget.onFavorite != null)
              _overlayIconButton(
                tooltip: widget.favorite
                    ? l10n.detailUnfollow
                    : l10n.detailFollow,
                onPressed: widget.onFavorite,
                icon: widget.favorite
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_add_outlined,
              ),
            if (compact)
              _overlayIconButton(
                tooltip: l10n.rotateFullscreen,
                onPressed: widget.onFullscreen,
                icon: Icons.screen_rotation_alt_rounded,
              ),
          ],
        ),
      ),
    );
  }

  Widget _overlayIconButton({
    required String tooltip,
    required VoidCallback? onPressed,
    required IconData icon,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Md3PlayerOverlay.pillBackground,
        borderRadius: Md3Shape.pill,
      ),
      child: IconButton(
        tooltip: tooltip,
        constraints: const BoxConstraints.tightFor(width: 42, height: 42),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        icon: Icon(icon),
      ),
    ),
  );

  Widget _playButton({double iconSize = 28}) => IconButton(
    tooltip: widget.player.state.playing
        ? l10n.pausePlayback
        : l10n.startPlayback,
    iconSize: iconSize,
    onPressed: widget.enabled
        ? () {
            widget.onTogglePlayback();
            _show();
          }
        : null,
    icon: Icon(
      widget.player.state.playing
          ? Icons.pause_rounded
          : Icons.play_arrow_rounded,
    ),
  );

  Widget _nextButton() => IconButton(
    tooltip: l10n.nextEpisode,
    onPressed: widget.onNext,
    icon: const Icon(Icons.skip_next_rounded),
  );

  Widget _timeLabel(double position, double duration) => Text(
    '${formatPosition(_seekValue ?? position)} / ${formatPosition(duration)}',
    style: TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );

  Widget _fullscreenButton() => IconButton(
    tooltip: widget.fullscreen ? l10n.exitFullscreen : l10n.rotateFullscreen,
    onPressed: widget.onFullscreen,
    icon: Icon(
      widget.fullscreen
          ? Icons.fullscreen_exit_rounded
          : Icons.fullscreen_rounded,
    ),
  );

  Widget _sideDanmakuControl() {
    if (!widget.showDanmaku) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: EdgeInsets.only(right: widget.swipeEnabled ? 0 : 4),
        child: _danmakuTool(),
      ),
    );
  }

  Widget _bottomControls({
    required BoxConstraints constraints,
    required double volume,
    required double duration,
    required double position,
    required double buffered,
    required bool playing,
  }) {
    final width = constraints.maxWidth;
    final fullscreen = widget.fullscreen;
    final mobile = widget.swipeEnabled;
    final showEpisodes = fullscreen;
    final showSpeedQuality =
        mobile || fullscreen && width >= 720 || !fullscreen && width >= 560;
    final showCompare = fullscreen && width >= 820;
    final showVolume = !widget.swipeEnabled && width >= 360;
    final track = _track(
      duration: duration,
      position: position,
      buffered: buffered,
    );
    if (mobile) {
      // 竖屏紧凑：播放 / 进度 / 时间 / 全屏，与参照应用 compact transport 一致。
      return Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
          child: Row(
            children: [
              _playButton(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: SizedBox(height: 28, child: track),
                ),
              ),
              _timeLabel(position, duration),
              _fullscreenButton(),
            ],
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.bottomCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: SizedBox(height: 28, child: track),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                _playButton(),
                _nextButton(),
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: _timeLabel(position, duration),
                ),
                Expanded(
                  child: _desktopControlRow(
                    fullscreen: fullscreen,
                    showEpisodes: showEpisodes,
                    showSpeedQuality: showSpeedQuality,
                    showCompare: showCompare,
                    showVolume: showVolume,
                    volume: volume,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  double _topChromeInset() {
    if (widget.fullscreen) {
      final top = MediaQuery.paddingOf(context).top;
      if (top <= 0) return 16;
      return (top + 16).clamp(40.0, 80.0);
    }
    if (widget.swipeEnabled) {
      return 10;
    }
    return 0;
  }

  double _bottomChromeInset() {
    if (widget.fullscreen) {
      return (MediaQuery.viewPaddingOf(context).bottom + 24).clamp(64.0, 104.0);
    }
    return 0;
  }

  Widget _track({
    required double duration,
    required double position,
    required double buffered,
  }) => PlayerProgressTrack(
    key: const ValueKey('player-progress'),
    position: _seekValue ?? position,
    buffered: buffered,
    duration: duration,
    enabled: widget.enabled,
    color: Theme.of(context).colorScheme.primary,
    onDragStart: () {
      widget.interactions.cancel();
      _hideTimer?.cancel();
    },
    onDragUpdate: (value) {
      _hideTimer?.cancel();
      setState(() => _seekValue = value);
    },
    onDragEnd: (value) {
      if (widget.enabled && duration > 0) {
        (widget.onSeek ?? widget.player.seek)(
          Duration(milliseconds: (value * 1000).round()),
        );
      }
      setState(() => _seekValue = null);
      _show();
    },
  );

  Widget _toolIcon({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool selected = false,
  }) => _toolButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    selected: selected,
    child: Icon(icon, size: 22),
  );

  Widget _toolText({
    required Key key,
    required String tooltip,
    required String label,
    required VoidCallback? onPressed,
    double width = 52,
  }) => _toolButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    visualWidth: width,
    child: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    ),
  );

  Widget _toolButton({
    required Key key,
    required String tooltip,
    required Widget child,
    required VoidCallback? onPressed,
    bool selected = false,
    double visualWidth = 36,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final foreground = selected
        ? scheme.primary
        : enabled
        ? Md3PlayerOverlay.toolForeground
        : Md3PlayerOverlay.toolDisabledForeground;
    final background = selected
        ? scheme.primary.withValues(alpha: .20)
        : Md3PlayerOverlay.toolBackground;
    final border = selected
        ? scheme.primary.withValues(alpha: .62)
        : Md3PlayerOverlay.toolBorder;
    final targetWidth = visualWidth < 40 ? 48.0 : visualWidth + 8;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: SizedBox(
            width: targetWidth,
            height: 48,
            child: Center(
              child: AnimatedContainer(
                duration: Md3Motion.of(context, Md3Motion.standardAccelerate),
                width: visualWidth,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: Md3Shape.pill,
                  border: Border.all(color: border),
                ),
                child: IconTheme.merge(
                  data: IconThemeData(color: foreground, size: 22),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      color: foreground,
                      fontSize: 13.5,
                      height: 1,
                      fontWeight: FontWeight.w700,
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolGroup(List<Widget> children) =>
      Row(mainAxisSize: MainAxisSize.min, children: children);

  Widget _clusteredToolRow(List<Widget> tools) {
    if (tools.isEmpty) return const SizedBox.shrink();
    if (tools.length <= 5) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [_toolGroup(tools)],
      );
    }
    final leftCount = tools.length ~/ 2;
    return Row(
      children: [
        _toolGroup(tools.take(leftCount).toList()),
        const Spacer(),
        _toolGroup(tools.skip(leftCount).toList()),
      ],
    );
  }

  Widget _danmakuTool() => _toolButton(
    key: const ValueKey('player-danmaku-toggle'),
    tooltip: widget.danmakuStatus.isEmpty
        ? (widget.danmakuEnabled ? l10n.danmakuOff : l10n.danmakuOn)
        : widget.danmakuStatus,
    visualWidth: 36,
    selected: widget.danmakuEnabled,
    onPressed: widget.enabled
        ? () => _panel(widget.onRetryDanmaku ?? widget.onDanmaku!)
        : null,
    child: widget.onRetryDanmaku != null
        ? const Icon(Icons.refresh_rounded, size: 21)
        : Text(
            l10n.danmakuShort,
            style: TextStyle(
              fontSize: 14,
              height: 1,
              fontWeight: FontWeight.w800,
              color: widget.danmakuEnabled
                  ? Theme.of(context).colorScheme.primary
                  : Md3PlayerOverlay.textForeground,
            ),
          ),
  );

  Widget _desktopControlRow({
    required bool fullscreen,
    required bool showEpisodes,
    required bool showSpeedQuality,
    required bool showCompare,
    required bool showVolume,
    required double volume,
  }) {
    final tools = [
      if (showSpeedQuality) ...[
        _toolText(
          key: const ValueKey('player-speed'),
          tooltip: l10n.speed,
          label: '${widget.speed}x',
          onPressed: widget.enabled ? () => _panel(widget.onSpeed) : null,
          width: 50,
        ),
        _toolText(
          key: const ValueKey('player-quality'),
          tooltip: l10n.clarity,
          label: widget.qualityLabel,
          onPressed: widget.enabled ? () => _panel(widget.onQuality) : null,
          width: 52,
        ),
      ],
      if (showEpisodes)
        _toolIcon(
          key: const ValueKey('player-episodes'),
          tooltip: l10n.episodes,
          icon: Icons.grid_view_rounded,
          onPressed: widget.enabled ? () => _panel(widget.onEpisodes) : null,
        ),
      if (showCompare) _enhancementCompareButton(),
      if (showVolume)
        _toolIcon(
          key: const ValueKey('player-volume'),
          tooltip: l10n.volume,
          icon: volume == 0
              ? Icons.volume_off_rounded
              : Icons.volume_up_rounded,
          onPressed: widget.enabled
              ? () => _panel(() => _openVolume(volume))
              : null,
        ),
      if (widget.onPictureInPicture != null)
        _toolIcon(
          key: const ValueKey('player-picture-in-picture'),
          tooltip: l10n.pictureInPicture,
          icon: Icons.picture_in_picture_alt_rounded,
          onPressed: widget.enabled
              ? () => _panel(widget.onPictureInPicture!)
              : null,
        ),
      _toolIcon(
        key: const ValueKey('player-fullscreen'),
        tooltip: fullscreen ? l10n.exitFullscreen : l10n.rotateFullscreen,
        icon: fullscreen
            ? Icons.fullscreen_exit_rounded
            : Icons.fullscreen_rounded,
        onPressed: widget.onFullscreen,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: _clusteredToolRow(tools),
    );
  }

  Widget _compactMoreMenu() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Md3PlayerOverlay.pillBackground,
        borderRadius: Md3Shape.pill,
      ),
      child: PopupMenuButton<String>(
        tooltip: l10n.more,
        icon: const Icon(Icons.more_vert, color: Colors.white),
        onSelected: (value) {
          switch (value) {
            case 'episodes':
              _panel(widget.onEpisodes);
            case 'speed':
              _panel(widget.onSpeed);
            case 'quality':
              _panel(widget.onQuality);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'episodes', child: Text(l10n.episodes)),
          PopupMenuItem(value: 'speed', child: Text(l10n.speed)),
          PopupMenuItem(value: 'quality', child: Text(l10n.clarity)),
        ],
      ),
    ),
  );

  Future<void> _openVolume(double initialVolume) async {
    var volume = initialVolume.clamp(0.0, 100.0);
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.transparent,
      transitionDuration: Md3Motion.of(context, Md3Motion.standardAccelerate),
      pageBuilder: (dialogContext, animation, secondaryAnimation) =>
          StatefulBuilder(
            builder: (context, setState) => SafeArea(
              child: Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: EdgeInsets.only(
                    right: widget.swipeEnabled ? 12 : 20,
                    bottom: widget.fullscreen ? 88 : 74,
                  ),
                  child: Material(
                    color: Md3PlayerOverlay.panelBackground,
                    borderRadius: Md3Shape.pill,
                    child: SizedBox(
                      width: 62,
                      height: 192,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: volume == 0
                                ? l10n.restoreVolume
                                : l10n.mute,
                            constraints: const BoxConstraints.tightFor(
                              width: 44,
                              height: 40,
                            ),
                            padding: EdgeInsets.zero,
                            onPressed: () {
                              final next = volume == 0 ? 100.0 : 0.0;
                              setState(() => volume = next);
                              unawaited(widget.player.setVolume(next));
                            },
                            icon: Icon(
                              volume == 0
                                  ? Icons.volume_off_rounded
                                  : Icons.volume_up_rounded,
                              size: 22,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(
                            width: 44,
                            height: 112,
                            child: RotatedBox(
                              quarterTurns: -1,
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 3,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6,
                                  ),
                                  overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 14,
                                  ),
                                ),
                                child: Slider(
                                  value: volume,
                                  max: 100,
                                  divisions: 20,
                                  onChanged: (value) {
                                    setState(() => volume = value);
                                    unawaited(widget.player.setVolume(value));
                                  },
                                ),
                              ),
                            ),
                          ),
                          SizedBox(
                            height: 28,
                            child: Center(
                              child: Text(
                                '${volume.round()}%',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(.04, .08),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
              child: child,
            ),
          ),
    );
  }

  Widget _enhancementCompareButton() {
    final enhancement = widget.enhancement;
    if (enhancement == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: enhancement,
      builder: (_, _) {
        if (!enhancement.canCompare) return const SizedBox.shrink();
        return _toolIcon(
          key: const ValueKey('player-enhancement-compare'),
          tooltip: enhancement.comparing
              ? l10n.comparingOriginal
              : l10n.compareOriginal,
          icon: Icons.compare_rounded,
          onPressed: widget.enabled
              ? () {
                  widget.interactions.cancel();
                  unawaited(enhancement.toggleCompare());
                  _show();
                }
              : null,
          selected: enhancement.comparing,
        );
      },
    );
  }

  Widget _gestureFeedback() => AnimatedBuilder(
    animation: widget.interactions,
    builder: (context, _) {
      final feedback = widget.interactions.feedback;
      if (feedback.isEmpty) return const SizedBox.shrink();
      return IgnorePointer(
        child: Align(
          alignment: const Alignment(0, -.5),
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(Md3Shape.small),
            ),
            child: Text(feedback, textAlign: TextAlign.center),
          ),
        ),
      );
    },
  );
}

/// 播放器遮罩的一段。
///
/// 参照应用把上下遮罩拆成两个固定高度的渐变条，而不是一条覆盖整屏的
/// 渐变：这样画面中段完全不受影响。
class _Scrim extends StatelessWidget {
  const _Scrim({required this.height, required this.colors});

  final double height;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
        ),
      ),
    ),
  );
}

/// 轨道与拇指尺寸。数值来自参照应用的 `player_progress_bar.dart`。
const double _progressBarHeight = 5;
const double _progressThumbRadius = 8;
const double _progressGlowRadius = 18;

/// 播放进度条（自绘）。
///
/// 数值照参照应用的 `player_progress_bar.dart`：轨道 5 高、底轨用主色
/// @ .24、已缓冲同色、已播放实色；拇指 r8，按下时外面加一圈 r18 光晕。
///
/// 不用 Material `Slider` 的原因是它把「轨道高度 / 拇指半径 / 光晕半径」
/// 当成三套独立参数，且默认带一层 overlay 涟漪——在黑底播放器上那层
/// 涟漪会盖住画面。自绘只有一个 `CustomPaint`，拖动时也不会触发涟漪。
class PlayerProgressTrack extends StatefulWidget {
  const PlayerProgressTrack({
    super.key,
    required this.position,
    required this.buffered,
    required this.duration,
    required this.enabled,
    required this.color,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final double position;
  final double buffered;
  final double duration;
  final bool enabled;
  final Color color;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final ValueChanged<double> onDragEnd;

  @override
  State<PlayerProgressTrack> createState() => _PlayerProgressTrackState();
}

class _PlayerProgressTrackState extends State<PlayerProgressTrack> {
  bool _dragging = false;

  double get _max => widget.duration > 0 ? widget.duration : 1;

  double _fractionOf(double value) => (value / _max).clamp(0.0, 1.0);

  void _update(Offset local, double width) {
    final fraction = (local.dx / width).clamp(0.0, 1.0);
    widget.onDragUpdate(fraction * _max);
  }

  @override
  Widget build(BuildContext context) {
    final played = _fractionOf(widget.position);
    final buffered = _fractionOf(widget.buffered);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: widget.enabled
              ? (details) {
                  setState(() => _dragging = true);
                  widget.onDragStart();
                  _update(details.localPosition, width);
                }
              : null,
          onHorizontalDragUpdate: widget.enabled
              ? (details) => _update(details.localPosition, width)
              : null,
          onHorizontalDragEnd: widget.enabled
              ? (_) {
                  setState(() => _dragging = false);
                  widget.onDragEnd(_fractionOf(widget.position) * _max);
                }
              : null,
          onTapDown: widget.enabled
              ? (details) {
                  widget.onDragStart();
                  _update(details.localPosition, width);
                  widget.onDragEnd(_fractionOf(widget.position) * _max);
                }
              : null,
          child: Semantics(
            slider: true,
            value: formatPosition(widget.position),
            child: CustomPaint(
              size: Size(width, _progressGlowRadius * 2),
              painter: _ProgressPainter(
                played: played,
                buffered: buffered,
                color: widget.color,
                dragging: _dragging,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ProgressPainter extends CustomPainter {
  _ProgressPainter({
    required this.played,
    required this.buffered,
    required this.color,
    required this.dragging,
  });

  final double played;
  final double buffered;
  final Color color;
  final bool dragging;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    // 轨道左右各留出拇指半径，否则拖到两端时拇指会被裁掉一半。
    const inset = _progressThumbRadius;
    final left = inset;
    final right = size.width - inset;
    final trackWidth = right - left;
    if (trackWidth <= 0) return;

    final track = Paint()
      ..color = color.withValues(alpha: .24)
      ..strokeWidth = _progressBarHeight
      ..strokeCap = StrokeCap.round;
    final active = Paint()
      ..color = color
      ..strokeWidth = _progressBarHeight
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(left, centerY), Offset(right, centerY), track);
    if (buffered > 0) {
      canvas.drawLine(
        Offset(left, centerY),
        Offset(left + trackWidth * buffered, centerY),
        track,
      );
    }
    if (played > 0) {
      canvas.drawLine(
        Offset(left, centerY),
        Offset(left + trackWidth * played, centerY),
        active,
      );
    }

    final thumbX = left + trackWidth * played;
    if (dragging) {
      canvas.drawCircle(
        Offset(thumbX, centerY),
        _progressGlowRadius,
        Paint()..color = color.withValues(alpha: 80 / 255),
      );
    }
    canvas.drawCircle(
      Offset(thumbX, centerY),
      _progressThumbRadius,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_ProgressPainter oldDelegate) =>
      played != oldDelegate.played ||
      buffered != oldDelegate.buffered ||
      color != oldDelegate.color ||
      dragging != oldDelegate.dragging;
}
