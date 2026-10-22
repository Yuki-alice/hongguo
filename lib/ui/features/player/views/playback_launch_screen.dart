import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/domain/follow_state.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/routing/app_router.dart';
import 'package:hoshi/ui/routing/route_args.dart';
import 'package:hoshi/ui/core/widgets.dart';

Future<void> openPlaybackDirectly(
  BuildContext context, {
  required Drama drama,
  required AppRepository repository,
  required LocalStore store,
}) async {
  final profileEpoch = store.profileEpoch;
  final l10n = AppLocalizations.of(context);
  try {
    final detail = await repository.detail(drama);
    if (!context.mounted || profileEpoch != store.profileEpoch) return;
    final mergedDrama = repository.catalogUpdates
        .current(drama)
        .merge(detail.drama);
    final merged = DramaDetail(
      mergedDrama,
      detail.episodes,
      warning: detail.warning,
    );
    repository.catalogUpdates.publish(mergedDrama, retryCover: true);
    await saveUserChange(context, () => store.refreshDrama(mergedDrama));
    if (!context.mounted || profileEpoch != store.profileEpoch) return;
    if (merged.episodes.isEmpty) {
      throw AppFailure(l10n.noPlayableEpisodes);
    }
    final watched = store.watched(mergedDrama.id);
    final index = resumeEpisodeIndex(merged.episodes, watched);
    final episode = merged.episodes[index];
    if (episode.vip && mergedDrama.source != SourceSite.dsd.id) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.detailVipDialogTitle),
          content: Text(l10n.detailVipWarning),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.detailTryPlay),
            ),
          ],
        ),
      );
      if (accepted != true || !context.mounted) return;
    }
    final position =
        watched?.episode == episode.number && watched?.finished == false
        ? watched!.position
        : 0.0;
    if (!context.mounted || profileEpoch != store.profileEpoch) return;
    final ref = DramaRef.fromDramaId(merged.drama.id);
    if (ref == null) return;
    await context.push(
      AppRoutes.playerOf(ref),
      extra: PlayerRouteExtra(
        detail: merged,
        initialIndex: index,
        initialPosition: position,
      ),
    );
  } catch (error) {
    if (!context.mounted || profileEpoch != store.profileEpoch) return;
    repository.catalogUpdates.publish(
      repository.catalogUpdates.current(drama),
      retryCover: true,
    );
    final message = error is AppFailure ? error.message : l10n.cannotPlayRetry;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class PlaybackLaunchScreen extends StatefulWidget {
  const PlaybackLaunchScreen({
    super.key,
    required this.drama,
    required this.repository,
    required this.store,
  });

  final Drama drama;
  final AppRepository repository;
  final LocalStore store;

  @override
  State<PlaybackLaunchScreen> createState() => _PlaybackLaunchScreenState();
}

class _PlaybackLaunchScreenState extends State<PlaybackLaunchScreen> {
  AppLocalizations get l10n => AppLocalizations.of(context);
  late final int _profileEpoch;
  int _generation = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _profileEpoch = widget.store.profileEpoch;
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() => _error = null);
    try {
      final detail = await widget.repository.detail(widget.drama);
      if (!mounted ||
          generation != _generation ||
          _profileEpoch != widget.store.profileEpoch) {
        return;
      }
      final drama = widget.repository.catalogUpdates
          .current(widget.drama)
          .merge(detail.drama);
      final merged = DramaDetail(
        drama,
        detail.episodes,
        warning: detail.warning,
      );
      widget.repository.catalogUpdates.publish(drama, retryCover: true);
      await saveUserChange(context, () => widget.store.refreshDrama(drama));
      if (!mounted ||
          generation != _generation ||
          _profileEpoch != widget.store.profileEpoch) {
        return;
      }
      if (merged.episodes.isEmpty) {
        setState(() => _error = l10n.noPlayableEpisodes);
        return;
      }
      final watched = widget.store.watched(drama.id);
      final index = resumeEpisodeIndex(merged.episodes, watched);
      final episode = merged.episodes[index];
      if (episode.vip && drama.source != SourceSite.dsd.id) {
        if (!mounted) return;
        final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.detailVipDialogTitle),
            content: Text(l10n.detailVipWarning),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.detailTryPlay),
              ),
            ],
          ),
        );
        if (accepted != true) {
          if (mounted) Navigator.of(context).maybePop();
          return;
        }
        if (!mounted) {
          return;
        }
      }
      final position =
          watched?.episode == episode.number && watched?.finished == false
          ? watched!.position
          : 0.0;
      if (!mounted ||
          generation != _generation ||
          _profileEpoch != widget.store.profileEpoch) {
        return;
      }
      final ref = DramaRef.fromDramaId(merged.drama.id);
      if (ref == null) return;
      // `replace` 而不是 `push`：启动页只是过渡，返回时不应回到它。
      context.replace(
        AppRoutes.playerOf(ref),
        extra: PlayerRouteExtra(
          detail: merged,
          initialIndex: index,
          initialPosition: position,
        ),
      );
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = error.toString());
      widget.repository.catalogUpdates.publish(
        widget.repository.catalogUpdates.current(widget.drama),
        retryCover: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.drama.title)),
      body: SafeArea(
        top: false,
        child: _error == null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(l10n.enteringPlayback),
                  ],
                ),
              )
            : StatusPanel(
                title: l10n.playerCannotPlay,
                message: _error!,
                onRetry: _load,
                action: l10n.retry,
                icon: Icons.play_disabled_rounded,
              ),
      ),
    );
  }
}
