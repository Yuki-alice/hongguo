import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/domain/models.dart';
import 'package:duanju_app/l10n/generated/app_localizations.dart';
import 'package:duanju_app/domain/ranking_models.dart';
import 'package:duanju_app/ui/features/rankings/views/rankings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../fixtures.dart';

class _RankingRepository extends FixtureRepository {
  _RankingRepository(this.source);

  final String source;
  final responses = <String, RankingPage>{};
  final calls = <String>[];

  @override
  Future<List<RankingBoard>> rankingBoards() async => [
    RankingBoard(id: 'b1', source: source, name: '榜一'),
    RankingBoard(id: 'b2', source: source, name: '榜二'),
  ];

  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async {
    calls.add('$board:$page');
    return responses['$board:$page'] ?? const RankingPage(items: []);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('榜单页加载、切换榜单并展示条目', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final source = store.sources.first.id;
    final repository = _RankingRepository(source);
    repository.responses['b1:1'] = RankingPage(
      items: [
        RankingItem(1, Drama(id: '$source:1', source: source, title: '剧一')),
      ],
      page: 1,
    );
    repository.responses['b2:1'] = RankingPage(
      items: [
        RankingItem(1, Drama(id: '$source:2', source: source, title: '剧二')),
      ],
      page: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RankingsScreen(
          repository: repository,
          store: store,
          initialGroup: SourceSite.byId(source).groupId,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('榜一'), findsOneWidget);
    expect(find.text('剧一'), findsOneWidget);
    expect(repository.calls, ['b1:1']);

    await tester.tap(find.text('榜二'));
    await tester.pumpAndSettle();

    expect(find.text('剧二'), findsOneWidget);
    expect(repository.calls.last, 'b2:1');

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
