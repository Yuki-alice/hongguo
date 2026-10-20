import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:duanju_app/domain/models.dart';
import 'package:duanju_app/l10n/generated/app_localizations.dart';
import 'package:duanju_app/ui/core/episode_browser.dart';
import 'package:duanju_app/domain/playback_preferences.dart';
import 'package:duanju_app/data/video_enhancement/video_enhancement.dart';
import 'package:duanju_app/ui/features/player/widgets/video_enhancement_settings.dart';

enum PlayerMenuSection { episodes, speed, quality, settings }

class PlayerMenu extends StatefulWidget {
  const PlayerMenu({
    super.key,
    required this.section,
    required this.episodes,
    required this.currentIndex,
    required this.preferences,
    required this.qualities,
    required this.actualQuality,
    required this.local,
    required this.favorite,
    required this.mobile,
    required this.onEpisode,
    required this.onPreferences,
    required this.onFavorite,
    this.showDanmaku = false,
    this.danmakuStatus = '',
    this.onRetryDanmaku,
    this.preloadStatus = '',
    this.enhancement,
    this.onCompareEnhancement,
  });

  final PlayerMenuSection section;
  final List<Episode> episodes;
  final int currentIndex;
  final PlaybackPreferences preferences;
  final List<int> qualities;
  final int actualQuality;
  final bool local;
  final bool favorite;
  final bool mobile;
  final bool showDanmaku;
  final String danmakuStatus;
  final VoidCallback? onRetryDanmaku;
  final String preloadStatus;
  final VideoEnhancementController? enhancement;
  final VoidCallback? onCompareEnhancement;
  final ValueChanged<int> onEpisode;
  final Future<void> Function(PlaybackPreferences) onPreferences;
  final Future<void> Function() onFavorite;

  @override
  State<PlayerMenu> createState() => _PlayerMenuState();
}

class _PlayerMenuState extends State<PlayerMenu> {
  AppLocalizations get l10n => AppLocalizations.of(context);
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = l10n.saveSettingsFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final landscape = size.width > size.height;
    final colors = Theme.of(context).colorScheme;
    final title = switch (widget.section) {
      PlayerMenuSection.episodes => l10n.episodeTotal(widget.episodes.length),
      PlayerMenuSection.speed => l10n.playbackSpeed,
      PlayerMenuSection.quality => l10n.clarity,
      PlayerMenuSection.settings => l10n.playbackSettings,
    };
    return Dialog(
      key: const ValueKey('player-menu'),
      alignment: landscape ? Alignment.centerRight : Alignment.bottomCenter,
      insetPadding: const EdgeInsets.all(12),
      backgroundColor: colors.surface,
      child: SizedBox(
        width: landscape ? math.min(440, size.width * .6) : 600,
        height: landscape ? size.height : size.height * .72,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.closeMenu,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 8,
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: widget.section == PlayerMenuSection.episodes
                  ? PlayerEpisodeGrid(
                      episodes: widget.episodes,
                      currentIndex: widget.currentIndex,
                      keyPrefix: 'menu-episode',
                      onSelected: widget.onEpisode,
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(18, 4, 18, 20),
                      child: _settings(),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _settings() {
    final preferences = widget.preferences;
    final all = widget.section == PlayerMenuSection.settings;
    final colors = Theme.of(context).colorScheme;
    final helperStyle = TextStyle(
      fontSize: 13,
      color: colors.onSurfaceVariant,
      height: 1.5,
    );
    final qualities = {
      0,
      ...widget.qualities.where((quality) => quality > 0),
    }.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (all || widget.section == PlayerMenuSection.speed) ...[
          Text(l10n.speed),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final speed in playbackSpeeds)
                ChoiceChip(
                  key: ValueKey('menu-speed-$speed'),
                  label: Text('${speed}x'),
                  selected: speed == preferences.speed,
                  onSelected: _busy
                      ? null
                      : (_) => _run(
                          () => widget.onPreferences(
                            preferences.copyWith(speed: speed),
                          ),
                        ),
                ),
            ],
          ),
          const SizedBox(height: 20),
        ],
        if (all || widget.section == PlayerMenuSection.quality) ...[
          Text(l10n.clarity),
          const SizedBox(height: 8),
          Text(
            widget.local
                ? l10n.localQualityHint
                : widget.actualQuality > 0
                ? l10n.actualQuality(widget.actualQuality)
                : l10n.useAvailableQuality,
            style: helperStyle,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final quality in qualities)
                ChoiceChip(
                  key: ValueKey('menu-quality-$quality'),
                  label: Text(
                    quality == 0 ? l10n.autoHighParen : '${quality}P',
                  ),
                  selected: quality == preferences.quality,
                  onSelected: _busy
                      ? null
                      : (_) => _run(
                          () => widget.onPreferences(
                            preferences.copyWith(quality: quality),
                          ),
                        ),
                ),
            ],
          ),
          if (!qualities.contains(preferences.quality))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l10n.qualityPrefFallback(preferences.quality),
                style: helperStyle,
              ),
            ),
          const SizedBox(height: 20),
        ],
        if ((all || widget.section == PlayerMenuSection.quality) &&
            widget.enhancement != null)
          VideoEnhancementSettings(
            controller: widget.enhancement!,
            busy: _busy,
            onChanged: (enhancement) => _run(
              () => widget.onPreferences(
                preferences.copyWith(enhancement: enhancement),
              ),
            ),
            onCompare: widget.onCompareEnhancement ?? () {},
          ),
        if (all && widget.showDanmaku) ...[
          SwitchListTile.adaptive(
            key: const ValueKey('player-danmaku-enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.danmaku),
            subtitle: Text(widget.danmakuStatus),
            value: preferences.danmaku,
            onChanged: _busy
                ? null
                : (value) => _run(
                    () => widget.onPreferences(
                      preferences.copyWith(danmaku: value),
                    ),
                  ),
          ),
          if (widget.onRetryDanmaku != null)
            TextButton.icon(
              key: const ValueKey('player-danmaku-retry'),
              onPressed: _busy ? null : widget.onRetryDanmaku,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(l10n.retryDanmaku),
            ),
          const SizedBox(height: 8),
        ],
        if (all) ...[
          SwitchListTile.adaptive(
            key: const ValueKey('player-preload-enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.preloadNext),
            subtitle: Text(
              widget.local ? l10n.localNoPreload : widget.preloadStatus,
            ),
            value: preferences.preload,
            onChanged: _busy
                ? null
                : (value) => _run(
                    () => widget.onPreferences(
                      preferences.copyWith(preload: value),
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            key: const ValueKey('player-auto-advance'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.autoAdvance),
            subtitle: Text(l10n.autoAdvanceStopHint),
            value: preferences.autoAdvance,
            onChanged: _busy
                ? null
                : (value) => _run(
                    () => widget.onPreferences(
                      preferences.copyWith(autoAdvance: value),
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('player-favorite'),
            onPressed: _busy ? null : () => _run(widget.onFavorite),
            icon: Icon(
              widget.favorite
                  ? Icons.bookmark_rounded
                  : Icons.bookmark_border_rounded,
            ),
            label: Text(
              widget.favorite ? l10n.detailUnfollow : l10n.detailFollow,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            widget.mobile ? l10n.playerMenuHint : l10n.keyboardHelp,
            style: helperStyle.copyWith(height: 1.6),
          ),
        ],
      ],
    );
  }
}

class PlayerEpisodeGrid extends StatelessWidget {
  const PlayerEpisodeGrid({
    super.key,
    required this.episodes,
    required this.currentIndex,
    required this.onSelected,
    this.keyPrefix = 'play-episode',
    this.compact = false,
    this.title,
  });
  final List<Episode> episodes;
  final int currentIndex;
  final ValueChanged<int> onSelected;
  final String keyPrefix;
  final bool compact;
  final String? title;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return EpisodeBrowser(
      episodes: episodes,
      currentNumber: episodes.isEmpty
          ? null
          : episodes[currentIndex.clamp(0, episodes.length - 1)].number,
      onSelected: onSelected,
      keyPrefix: keyPrefix,
      compact: compact,
      title: title ?? l10n.episodes,
    );
  }
}
