import 'package:flutter/material.dart';

import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/features/home/widgets/saved_library.dart';
import 'package:hoshi/ui/features/player/views/playback_launch_screen.dart';

/// 历史记录页。
///
/// S1 之前历史是外壳的一个分支，与发现 / 追剧 / 下载平级。改成「我的」
/// 的下级页面后，它需要自己的 `Scaffold` + 返回按钮——这也是 `UI.md`
/// §3 一直写的规则：除 4 个 tab 外都不进外壳。
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({
    super.key,
    required this.repository,
    required this.store,
  });

  final AppRepository repository;
  final LocalStore store;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.recentlyWatched),
        leading: const BackButton(),
      ),
      body: SafeArea(
        top: false,
        child: SavedLibrary(
          key: const ValueKey('saved-tab-history'),
          repository: repository,
          store: store,
          history: true,
          onOpen: (drama) => _open(context, drama),
          onContinue: (drama) => _open(context, drama),
        ),
      ),
    );
  }

  void _open(BuildContext context, Drama drama) => openPlaybackDirectly(
    context,
    drama: drama,
    repository: repository,
    store: store,
  );
}
