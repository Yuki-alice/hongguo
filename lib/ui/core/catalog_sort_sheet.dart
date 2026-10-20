import 'package:flutter/material.dart';

import 'package:duanju_app/ui/core/app_layout.dart';
import 'package:duanju_app/domain/catalog_sort.dart';
import 'package:duanju_app/l10n/generated/app_localizations.dart';
import 'package:duanju_app/ui/core/l10n_labels.dart';

Future<CatalogView?> chooseCatalogView(
  BuildContext context,
  CatalogView current,
) => showModalBottomSheet<CatalogView>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) {
    final l10n = AppLocalizations.of(context);
    var selected = current;
    return StatefulBuilder(
      builder: (context, update) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.sortAndFilterTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final sort in CatalogSort.values)
                  ChoiceChip(
                    autofocus:
                        AppLayout.isTelevision(context) &&
                        sort == CatalogSort.values.first,
                    label: Text(catalogSortLabel(sort, l10n)),
                    selected: selected.sort == sort,
                    onSelected: (_) =>
                        update(() => selected = selected.copyWith(sort: sort)),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            Text(l10n.episodeStatusFilter),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in {
                  '': l10n.filterAll,
                  'ongoing': l10n.releaseOngoing,
                  'finished': l10n.releaseFinished,
                  'unknown': l10n.statusUnknown,
                }.entries)
                  ChoiceChip(
                    label: Text(entry.value),
                    selected: selected.release == entry.key,
                    onSelected: (_) => update(
                      () => selected = selected.copyWith(release: entry.key),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              l10n.sortFilterHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, selected),
                child: Text(l10n.apply),
              ),
            ),
          ],
        ),
      ),
    );
  },
);
