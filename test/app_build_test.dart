import 'dart:convert';

import 'package:hoshi/app_build.dart';
import 'package:hoshi/data/local_profiles.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/data/engine_backed_repository.dart';
import 'package:hoshi/data/engine_repository.dart';
import 'package:hoshi/data/engine_failure.dart';
import 'package:hoshi/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const red = FixtureRepository.free;
  const other = FixtureRepository.vip;

  test('edition sources include DSD only in the all-source build', () async {
    SharedPreferences.setMockInitialValues({
      'source': SourceSite.legacyHuangdou,
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    expect(appSlug, 'hoshi');
    // 不写死条数：源清单随站源迁移增长，硬编码会在每次新增源时假失败。
    // 这里只断言两个版本的相对关系——单源版仅红果，全源版明显更多。
    expect(store.sources.length, allSourcesEnabled ? greaterThan(1) : 1);
    expect(
      SourceSite.values.any((source) => source.id == 'dsd'),
      allSourcesEnabled,
    );
    expect(SourceSite.isAvailable('dsd'), allSourcesEnabled);
    expect(SourceSite.isKnown('dsd'), isTrue);
    expect(SourceSite.byId('dsd').name, '帝果');
    // 默认档案是管理员，可用源都能用：dsd 只在全源版可用。
    expect(store.allowsSource('dsd'), allSourcesEnabled);
    // 黄豆已下线：旧数据里的 `huangdou` 不算可用，`source` 回落到首个可用源。
    expect(store.allowsSource(SourceSite.legacyHuangdou), isFalse);
    expect(store.source, 'hongguo');
    store.dispose();
  });

  test(
    'edition filtering preserves favorites and history through backup restore',
    () async {
      final history = [
        for (final drama in [red, other])
          WatchEntry(
            drama: drama,
            episode: 1,
            position: 12,
            duration: 60,
            updatedAt: DateTime(2026, 9, 19),
          ).toJson(),
      ];
      SharedPreferences.setMockInitialValues({
        'source': SourceSite.legacyHuangdou,
        'favorites': jsonEncode([red.toJson(), other.toJson()]),
        'history': jsonEncode(history),
      });
      final store = LocalStore(await SharedPreferences.getInstance());
      // `other` 属于剧果（全源版可用，单源版不可用）。
      // 黄豆已下线，不再参与这两种构建的差异。
      expect(store.favorites.length, allSourcesEnabled ? 2 : 1);
      expect(store.history.length, allSourcesEnabled ? 2 : 1);
      expect(store.isFavorite(other.id), allSourcesEnabled);
      expect(store.watched(other.id) != null, allSourcesEnabled);
      // red 在可用源里，取消收藏会生效。
      await store.toggleFavorite(red);
      final backup = await store.exportBackup();
      final library =
          (jsonDecode(backup)['libraries'] as Map)['default'] as Map;
      // 导出不过滤站源：磁盘上仍有两条，red 刚被取消收藏，因此只剩 other。
      expect((library['favorites'] as List).map((row) => (row as Map)['id']), [
        other.id,
      ]);
      expect(library['history'], hasLength(2));
      await store.importBackup(backup);
      expect(store.preferences.getString('source'), SourceSite.legacyHuangdou);
      expect(store.history, hasLength(allSourcesEnabled ? 2 : 1));
      expect(
        store.favorites.map((drama) => drama.id),
        allSourcesEnabled ? [other.id] : isEmpty,
      );
      store.dispose();
    },
  );

  test(
    'a restored foreign-source profile keeps its identity and permissions',
    () async {
      SharedPreferences.setMockInitialValues({
        'profiles': jsonEncode([
          LocalProfile(
            id: 'default',
            name: '管理员',
            admin: true,
            salt: '0' * 32,
            pinHash: '1' * 64,
          ).toJson(),
          const LocalProfile(
            id: 'viewer',
            name: '已有用户',
            sources: ['huangju'],
            download: false,
          ).toJson(),
        ]),
        'activeProfile': 'viewer',
        'profile.viewer.source': 'huangju',
      });
      final store = LocalStore(await SharedPreferences.getInstance());
      expect(store.profile.id, 'viewer');
      expect(store.profile.admin, isFalse);
      // 档案里记录的源原样保留（导入 / 导出不能丢身份）。
      expect(store.profile.sources, ['huangju']);
      expect(store.canDownload, isFalse);
      // 剧果只在全源版可用：单源版下 profile 允许的源被过滤空，`source` 为空。
      expect(store.source, allSourcesEnabled ? 'huangju' : '');
      expect(store.allowsSource('hongguo'), isFalse);
      expect(store.allowsSource('huangju'), allSourcesEnabled);
      store.dispose();
    },
  );

  test('restored DSD profile data follows edition availability', () async {
    SharedPreferences.setMockInitialValues({
      'profiles': jsonEncode([
        LocalProfile(
          id: 'default',
          name: '管理员',
          admin: true,
          salt: '0' * 32,
          pinHash: '1' * 64,
        ).toJson(),
        const LocalProfile(
          id: 'viewer',
          name: '帝果旧用户',
          sources: ['dsd'],
          download: false,
        ).toJson(),
      ]),
      'activeProfile': 'viewer',
      'profile.viewer.source': 'dsd',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    expect(store.configurationError, isNull);
    expect(store.profile.sources, ['dsd']);
    expect(
      store.sources.map((source) => source.id),
      allSourcesEnabled ? ['dsd'] : [],
    );
    expect(store.source, allSourcesEnabled ? 'dsd' : '');
    expect(store.allowsSource('dsd'), allSourcesEnabled);
    store.dispose();
  });

  test('未就绪的引擎拒绝一切请求，而不是静默降级', () async {
    // Go 后端在 Core-4 物理移除后，不再有「换一套实现继续跑」的回退路径。
    // 引擎未就绪时，站源入口必须直接不可用。
    final repository = EngineBackedRepository(
      engine: EngineRepository(initialized: false),
    );
    final denied = [
      ...SourceSite.knownValues.map((source) => source.id),
      'unknown',
    ];
    for (final source in denied) {
      final drama = Drama(id: '$source:123', source: source, title: '合成数据');
      final episode = Episode({'id': '1'}, 1);
      for (final request in [
        () => repository.catalog(source),
        () => repository.detail(drama),
        () => repository.resolve(drama, episode),
        () => repository.enqueueDownloads(DramaDetail(drama, [episode]), [
          episode,
        ]),
      ]) {
        await expectLater(
          request(),
          throwsA(isA<EngineException>()),
          reason: '源 $source 在引擎未就绪时不应发起请求',
        );
      }
    }
  });
}
