import 'package:duanju_app/domain/catalog_sort.dart';
import 'package:duanju_app/domain/follow_state.dart';
import 'package:duanju_app/l10n/generated/app_localizations.dart';

String catalogSortLabel(CatalogSort sort, AppLocalizations l10n) =>
    switch (sort) {
      CatalogSort.source => l10n.sortDefault,
      CatalogSort.name => l10n.sortName,
      CatalogSort.season => l10n.sortSeason,
      CatalogSort.date => l10n.sortDate,
      CatalogSort.heat => l10n.sortHeat,
      CatalogSort.views => l10n.sortViews,
    };

String followStatusLabel(FollowStatus status, AppLocalizations l10n) =>
    switch (status) {
      FollowStatus.planned => l10n.followPlanned,
      FollowStatus.watching => l10n.followWatching,
      FollowStatus.watched => l10n.followWatched,
    };
