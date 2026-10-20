import 'package:flutter/material.dart';

import 'package:duanju_app/domain/follow_state.dart';
import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/domain/models.dart';
import 'package:duanju_app/l10n/generated/app_localizations.dart';
import 'package:duanju_app/ui/core/widgets.dart';

String _statusLabel(FollowStatus status, AppLocalizations l10n) =>
    switch (status) {
      FollowStatus.planned => l10n.followPlanned,
      FollowStatus.watching => l10n.followWatching,
      FollowStatus.watched => l10n.followWatched,
    };

Future<void> showDramaActions(
  BuildContext context, {
  required Drama drama,
  required LocalStore store,
  VoidCallback? onContinue,
  VoidCallback? onDownload,
  VoidCallback? onSelect,
  bool history = false,
}) async {
  final epoch = store.profileEpoch;
  final l10n = AppLocalizations.of(context);
  final following = store.following(drama.id);
  final choices = <(String, String, IconData)>[
    if (onContinue != null && store.watched(drama.id) != null)
      ('continue', l10n.continueWatching, Icons.play_arrow_rounded),
    (
      'favorite',
      following == null ? l10n.detailFollow : l10n.detailUnfollow,
      Icons.bookmark_outline,
    ),
    for (final status in FollowStatus.values)
      (
        'status:${status.name}',
        l10n.markStatus(_statusLabel(status, l10n)),
        switch (status) {
          FollowStatus.planned => Icons.bookmark_add_outlined,
          FollowStatus.watching => Icons.play_circle_outline,
          FollowStatus.watched => Icons.check_circle_outline,
        },
      ),
    if (following != null && following.hasUpdates)
      (
        'read',
        l10n.markRead(following.updateLabel),
        Icons.mark_email_read_outlined,
      ),
    if (onDownload != null && store.canDownload)
      ('download', l10n.downloadPickerTitle, Icons.download_outlined),
    if (onSelect != null && store.canDownload)
      ('select', l10n.multiDownload, Icons.checklist_rounded),
    if (history && store.watched(drama.id) != null)
      ('removeHistory', l10n.deleteWatchRecord, Icons.history_toggle_off),
  ];
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(drama.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      children: [
        for (final entry in choices.indexed)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, entry.$2.$1),
            child: Row(
              children: [
                Icon(entry.$2.$3, size: 22),
                const SizedBox(width: 14),
                Expanded(child: Text(entry.$2.$2)),
                if (entry.$2.$1 == 'status:${following?.status.name}')
                  const Icon(Icons.check_rounded, size: 20),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 8),
          child: Text(
            l10n.manualMarkHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    ),
  );
  if (choice == null ||
      !context.mounted ||
      epoch != store.profileEpoch ||
      !store.allowsSource(drama.source)) {
    return;
  }
  if (choice.startsWith('status:')) {
    final status = FollowStatus.values.firstWhere(
      (value) => choice == 'status:${value.name}',
    );
    await saveUserChange(context, () => store.setFollowStatus(drama, status));
    return;
  }
  switch (choice) {
    case 'continue':
      onContinue?.call();
    case 'favorite':
      await saveUserChange(context, () => store.toggleFavorite(drama));
    case 'read':
      await saveUserChange(context, () => store.markUpdatesRead(drama.id));
    case 'download':
      if (store.canDownload) onDownload?.call();
    case 'select':
      if (store.canDownload) onSelect?.call();
    case 'removeHistory':
      await saveUserChange(context, () => store.removeHistory(drama.id));
  }
}

class DramaActionButton extends StatelessWidget {
  const DramaActionButton({
    super.key,
    required this.drama,
    required this.onPressed,
  });
  final Drama drama;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return IconButton.filledTonal(
      key: ValueKey('drama-actions-${drama.id}'),
      tooltip: l10n.dramaActionsTitle(drama.title),
      onPressed: onPressed,
      icon: const Icon(Icons.more_horiz_rounded, size: 20),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: .64),
        foregroundColor: Colors.white,
        minimumSize: const Size(40, 40),
        padding: const EdgeInsets.all(8),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
