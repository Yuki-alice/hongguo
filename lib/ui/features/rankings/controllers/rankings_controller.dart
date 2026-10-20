import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:duanju_app/data/core_bridge.dart';
import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/domain/ranking_models.dart';

/// 榜单页的加载、分页与榜单切换状态。
class RankingsController extends ChangeNotifier {
  RankingsController({
    required this.repository,
    required this.store,
    required this.initialGroup,
  }) {
    repository.catalogUpdates.addListener(_metadataChanged);
  }

  final AppRepository repository;
  final LocalStore store;
  final String initialGroup;

  List<RankingBoard> _boards = const [];
  RankingBoard? _board;
  List<RankingItem> _items = const [];
  bool _loading = true;
  bool _more = false;
  bool _hasMore = false;
  bool _failedMore = false;
  int _page = 1;
  int _generation = 0;
  String? _error;
  String _updated = '';
  bool _disposed = false;

  List<RankingBoard> get boards => _boards;
  RankingBoard? get board => _board;
  List<RankingItem> get items => _items;
  bool get loading => _loading;
  bool get more => _more;
  bool get hasMore => _hasMore;
  bool get failedMore => _failedMore;
  String? get error => _error;
  String get updated => _updated;

  Future<void> initialize() async {
    final generation = ++_generation;
    _loading = true;
    _error = null;
    _notify();
    try {
      final boards = (await repository.rankingBoards())
          .where((board) => store.allowsSource(board.source))
          .toList();
      if (_disposed || generation != _generation) return;
      _boards = boards;
      _board =
          boards.where((board) => board.groupId == initialGroup).firstOrNull ??
          boards.firstOrNull;
      _loading = false;
      _notify();
      if (_board != null) await load();
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _loading = false;
      _error = error.toString();
      _notify();
    }
  }

  Future<void> load({bool more = false, bool force = false}) async {
    final board = _board;
    if (board == null || more && (_loading || _more || !_hasMore)) return;
    final generation = ++_generation;
    _loading = !more;
    _more = more;
    _error = null;
    _failedMore = false;
    _notify();
    try {
      final result = await repository.rankings(
        board.id,
        page: more ? _page + 1 : 1,
        force: force,
      );
      if (_disposed || generation != _generation) return;
      final rows = <String, RankingItem>{
        if (more)
          for (final item in _items) item.drama.id: item,
        for (final item in result.items) item.drama.id: item,
      };
      _items = rows.values.toList()..sort((a, b) => a.rank.compareTo(b.rank));
      _page = result.page;
      _hasMore = result.hasMore;
      _updated = result.updatedText;
      _error = result.warning.isEmpty ? null : result.warning;
      _loading = false;
      _more = false;
      _notify();
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _error = error.toString();
      _failedMore = more;
      _loading = false;
      _more = false;
      _notify();
    }
  }

  void select(RankingBoard board) {
    if (_board?.id == board.id) return;
    _board = board;
    _items = const [];
    _updated = '';
    _page = 1;
    _hasMore = false;
    _notify();
    unawaited(load());
  }

  void _metadataChanged() {
    if (!_disposed) notifyListeners();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    repository.catalogUpdates.removeListener(_metadataChanged);
    super.dispose();
  }
}
