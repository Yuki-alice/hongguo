import 'package:flutter/material.dart';

import 'package:hoshi/domain/models.dart';
import 'package:hoshi/domain/download_preferences.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/episode_browser.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';

class DownloadSelection {
  const DownloadSelection(this.episodes, this.quality);
  final List<Episode> episodes;
  final int quality;
}

class DownloadPicker extends StatefulWidget {
  const DownloadPicker({
    super.key,
    required this.detail,
    this.preferences = const DownloadPreferences(),
    this.embedded = false,
    this.onSubmit,
  });
  final DramaDetail detail;
  final DownloadPreferences preferences;
  final bool embedded;
  final Future<void> Function(DownloadSelection selection)? onSubmit;

  @override
  State<DownloadPicker> createState() => _DownloadPickerState();
}

class _DownloadPickerState extends State<DownloadPicker> {
  late final _selected = widget.detail.episodes
      .where((episode) => widget.preferences.includeVip || !episode.vip)
      .take(500)
      .map((episode) => episode.number)
      .toSet();
  late int _quality = widget.preferences.quality;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
  }

  void _select(Iterable<Episode> episodes) {
    final choices = episodes.toList();
    setState(() {
      _selected.clear();
      _selected.addAll(choices.take(500).map((episode) => episode.number));
    });
    if (choices.length > 500) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).selectedFirst500)),
      );
    }
  }

  void _toggle(Episode episode) {
    if (!_selected.contains(episode.number) && _selected.length >= 500) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).downloadPickerMax)),
      );
      return;
    }
    setState(() {
      if (!_selected.remove(episode.number)) _selected.add(episode.number);
    });
  }

  Future<void> _submit() async {
    if (_selected.isEmpty || _submitting) return;
    final selection = DownloadSelection(
      widget.detail.episodes
          .where((episode) => _selected.contains(episode.number))
          .toList(),
      _quality,
    );
    if (widget.onSubmit == null) {
      if (mounted) Navigator.pop(context, selection);
      return;
    }
    setState(() => _submitting = true);
    try {
      await widget.onSubmit!(selection);
      if (mounted) setState(() => _selected.clear());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final episodes = widget.detail.episodes;
    final hasVip = episodes.any(
      (episode) => episode.vip && _selected.contains(episode.number),
    );
    final content = SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: Md3Spacing.contentMaxWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  widget.embedded ? 10 : 18,
                  widget.embedded ? 6 : 8,
                  widget.embedded ? 10 : 18,
                  0,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.embedded
                            ? l10n.downloadPickerTitle
                            : widget.detail.drama.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      l10n.selectedCount(_selected.length),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  widget.embedded ? 8 : 12,
                  6,
                  widget.embedded ? 8 : 12,
                  4,
                ),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton(
                      onPressed: _submitting ? null : () => _select(episodes),
                      child: Text(l10n.selectAll),
                    ),
                    TextButton(
                      onPressed: _submitting || _selected.isEmpty
                          ? null
                          : () => setState(() => _selected.clear()),
                      child: Text(
                        widget.embedded
                            ? l10n.clearSelection
                            : l10n.cancelSelectAll,
                      ),
                    ),
                    TextButton(
                      onPressed: _submitting
                          ? null
                          : () => _select(
                              episodes.where((episode) => !episode.vip),
                            ),
                      child: Text(l10n.onlyNonVip),
                    ),
                    const SizedBox(width: 4),
                    Text(l10n.quality),
                    DropdownButton<int>(
                      key: const ValueKey('download-quality'),
                      value: _quality,
                      onChanged: _submitting
                          ? null
                          : (value) => setState(() => _quality = value ?? 0),
                      items: [
                        DropdownMenuItem(value: 0, child: Text(l10n.autoHigh)),
                        for (final quality in [1080, 720, 480])
                          DropdownMenuItem(
                            value: quality,
                            child: Text('${quality}P'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: widget.embedded ? 10 : 18,
                ),
                child: Text(
                  l10n.originalQualityHint,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
              if (hasVip)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    widget.embedded ? 10 : 18,
                    6,
                    widget.embedded ? 10 : 18,
                    0,
                  ),
                  child: Text(
                    l10n.vipTrialHint,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.tertiary,
                      fontSize: 12,
                    ),
                  ),
                ),
              Expanded(
                child: EpisodeBrowser(
                  episodes: episodes,
                  selectedNumbers: _selected,
                  keyPrefix: 'download-episode',
                  compact: widget.embedded,
                  onSelected: (index) => _toggle(episodes[index]),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  widget.embedded ? 10 : 18,
                  0,
                  widget.embedded ? 10 : 18,
                  widget.embedded ? 8 : 16,
                ),
                child: FilledButton.icon(
                  key: const ValueKey('enqueue-downloads'),
                  onPressed: _selected.isEmpty || _submitting ? null : _submit,
                  icon: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_rounded),
                  label: Text(
                    _submitting
                        ? l10n.addingDownloads
                        : l10n.addDownloadsCount(_selected.length),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (widget.embedded) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: content,
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.downloadPickerTitle),
        automaticallyImplyLeading: true,
      ),
      body: content,
    );
  }
}
