import 'package:duanju_app/data/core_bridge.dart';
import 'package:duanju_app/data/engine_backed_repository.dart';
import 'package:duanju_app/data/repository_capabilities.dart';
import 'package:duanju_app/data/engine_repository.dart';
import 'package:duanju_app/domain/models.dart';
import 'package:duanju_app/domain/ranking_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 引擎接管榜单 / 推荐 / 联想之后的仓库行为。
///
/// 这些用例不触碰网络：假引擎只回答被调用的那部分，用来验证
/// 「谁被调用、结果怎么合并、失败怎么分类」。
class _FakeEngine extends EngineRepository {
  _FakeEngine() : super(initialized: true);

  final calls = <String>[];
  final sourcesResult = <SourceSummary>[
    const SourceSummary(
      id: 'hongguo',
      name: '红果',
      group: 'duanju',
      apiLevel: 1,
      capabilities: [
        'catalog',
        'detail',
        'search',
        'rankings',
        'recommend',
        'suggestions',
      ],
    ),
    const SourceSummary(
      id: 'wuguo',
      name: '伍果',
      group: 'duanju',
      apiLevel: 1,
      capabilities: ['catalog', 'detail'],
    ),
  ];

  /// 榜单看板按源返回；未知源抛 Unsupported。
  final boards = <String, List<RankingBoard>>{
    'hongguo': const [
      RankingBoard(id: 'hongguo-hot', source: 'hongguo', name: '总热播榜'),
    ],
  };

  /// 推荐页：按 offset 返回不同条目，便于验证累积。
  List<Drama> recommendPage(int offset) => [
    for (var i = offset; i < offset + 2; i++)
      Drama(
        id: 'hongguo:r$i',
        source: 'hongguo',
        sourceId: 'r$i',
        title: '推荐$i',
      ),
  ];

  @override
  Future<List<SourceSummary>> sources() async => sourcesResult;

  @override
  Future<List<RankingBoard>> rankingBoards(String source) async {
    calls.add('boards:$source');
    final rows = boards[source];
    if (rows == null) throw UnsupportedFailure('榜单');
    return rows;
  }

  @override
  Future<RankingPage> ranking(
    String source,
    String boardId, {
    int page = 1,
  }) async {
    calls.add('ranking:$source:$boardId:$page');
    return RankingPage(
      items: [
        RankingItem(
          1,
          const Drama(
            id: 'hongguo:1',
            source: 'hongguo',
            sourceId: '1',
            title: '第一',
          ),
        ),
      ],
      page: page,
      hasMore: true,
      updatedText: '今天',
    );
  }

  @override
  Future<RecommendPage> recommend(
    String source, {
    int offset = 0,
    String sessionId = '',
    String genre = '',
  }) async {
    calls.add('recommend:$genre:$offset:$sessionId');
    return RecommendPage(
      items: recommendPage(offset),
      offset: offset + 2,
      sessionId: 'session-$offset',
      hasMore: true,
    );
  }

  @override
  Future<List<String>> suggestions(String source, String keyword) async {
    calls.add('suggest:$source:$keyword');
    if (source != 'hongguo') throw UnsupportedFailure('搜索联想');
    return ['总裁'];
  }
}

/// 一个不会被调用的下层实现：任何调用都会让用例失败。
class _ForbiddenDelegate extends AppRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw StateError('不应调用下层：${invocation.memberName}');
  }

  @override
  Future<void> initialize() async {}
}

EngineBackedRepository build([_FakeEngine? engine]) => EngineBackedRepository(
  delegate: _ForbiddenDelegate(),
  engine: engine ?? _FakeEngine(),
);

void main() {
  test('榜单看板只向声明了 rankings 的源请求', () async {
    final engine = _FakeEngine();
    final boards = await build(engine).rankingBoards();
    expect(boards.map((board) => board.id), ['hongguo-hot']);
    // 伍果没有 rankings 能力，不应被请求。
    expect(engine.calls, ['boards:hongguo']);
  });

  test('榜单按看板 id 反查源并交给引擎', () async {
    final engine = _FakeEngine();
    final page = await build(engine).rankings('hongguo-hot', page: 2);
    expect(page.items.first.rank, 1);
    expect(engine.calls, ['ranking:hongguo:hongguo-hot:2']);
  });

  test('推荐翻页返回累积结果而不是增量', () async {
    final repository = build();
    final first = await repository.recommendations('短剧');
    expect(first.items.map((drama) => drama.id), ['hongguo:r0', 'hongguo:r1']);

    final next = await repository.recommendations('短剧', more: true);
    // 第二页必须包含第一页的条目，否则「加载更多」会冲掉已有内容。
    expect(next.items.map((drama) => drama.id), [
      'hongguo:r0',
      'hongguo:r1',
      'hongguo:r2',
      'hongguo:r3',
    ]);
    expect(next.hasMore, isTrue);
  });

  test('推荐游标在 genre 之间互不影响', () async {
    final engine = _FakeEngine();
    final repository = build(engine);
    await repository.recommendations('短剧');
    await repository.recommendations('漫剧');
    // 两个 genre 都从 offset 0 开始，说明游标按 genre 隔离。
    expect(
      engine.calls.where((call) => call.startsWith('recommend:')).toList(),
      ['recommend:短剧:0:', 'recommend:漫剧:0:'],
    );
  });

  test('联想只在主源上请求', () async {
    final engine = _FakeEngine();
    expect(await build(engine).suggestions('总裁'), ['总裁']);
    expect(engine.calls, ['suggest:hongguo:总裁']);
  });

  test('空关键词不触发请求', () async {
    final engine = _FakeEngine();
    expect(await build(engine).suggestions('   '), isEmpty);
    expect(engine.calls, isEmpty);
  });

  test('旧下载索引导入结果被原样映射', () async {
    final engine = _MigrationEngine();
    final repository = EngineBackedRepository(
      delegate: _StorageDelegate(),
      engine: engine,
    );
    await repository.initialize();
    final info = repository.legacyMigration;
    expect(info, isNotNull);
    expect(info!.found, isTrue);
    expect(info.imported, 2);
    expect(info.skipped['文件不存在'], 1);
  });

  test('重启后从索引重建下载列表而不是丢弃', () async {
    // 模拟「进程重启」：仓库刚构造，_downloads 为空，但引擎索引里仍有任务。
    final repository = EngineBackedRepository(
      delegate: _ForbiddenDelegate(),
      engine: _SnapshotEngine(),
    );
    final jobs = await repository.downloads();
    expect(jobs, hasLength(1), reason: '引擎任务不能因为重启而消失');
    final job = jobs.single;
    expect(job.drama.title, '重启测试剧');
    expect(job.drama.source, 'hongguo');
    expect(job.episode.number, 3);
    expect(job.state, 'completed');
  });

  test('旧索引缺少展示字段时跳过而不是崩溃', () async {
    final repository = EngineBackedRepository(
      delegate: _ForbiddenDelegate(),
      engine: _SnapshotEngine(dramaId: ''),
    );
    expect(await repository.downloads(), isEmpty);
  });

  test('能力矩阵如实标注未接入项', () {
    final capabilities = build().capabilities;
    expect(capabilities.rankings, isTrue);
    expect(capabilities.recommendations, isTrue);
    expect(capabilities.suggestions, isTrue);
    // 弹幕已接入：引擎按分集返回，Dart 侧补 60 秒窗口。
    expect(capabilities.danmaku, isTrue);
    expect(capabilities.lan, isFalse);
  });
}

/// 只回答迁移调用的假引擎。
class _MigrationEngine extends _FakeEngine {
  @override
  Future<LegacyMigrationInfo> importLegacyDownloads(String downloadRoot) async {
    calls.add('migrate:$downloadRoot');
    return const LegacyMigrationInfo(
      found: true,
      imported: 2,
      skipped: {'文件不存在': 1},
    );
  }
}

/// 提供旧下载目录的下层实现。
class _StorageDelegate extends _ForbiddenDelegate {
  @override
  Future<Map<String, dynamic>> storage() async => {'directory': '/legacy'};
}

/// 返回固定快照的假引擎，用于验证重启后的列表重建。
class _SnapshotEngine extends _FakeEngine {
  _SnapshotEngine({this.dramaId = 'hongguo:42'});
  final String dramaId;

  @override
  Future<List<DownloadSnapshotInfo>> downloads() async => [
    DownloadSnapshotInfo(
      id: 'hongguo:42:ep3',
      title: '第3集',
      state: 'completed',
      bytes: 100,
      total: 100,
      progress: 1,
      error: '',
      dramaId: dramaId,
      episodeId: 'ep3',
      dramaTitle: '重启测试剧',
      episodeIndex: 3,
      coverUrl: 'https://img.test/c.jpg',
    ),
  ];
}
