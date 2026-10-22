import 'dart:async';

import 'package:hoshi/domain/danmaku_models.dart';
import 'package:hoshi/domain/download_collections.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/domain/ranking_models.dart';
import 'package:hoshi/domain/resource_settings.dart';
import 'package:hoshi/data/catalog_updates.dart';
import 'package:hoshi/domain/source_status.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/data/repository_capabilities.dart';

/// 仓库层契约与通用失败类型。
///
/// 这两个类型原先与 Go 桥接代码同处 `core_bridge.dart`。Go 后端在 Core-4
/// 物理移除后，它们仍被引擎实现与 UI 使用，因此单独留在这里。

class AppFailure implements Exception {
  AppFailure(this.message, {this.code = ''});
  final String message;
  final String code;
  @override
  String toString() => message;
}

abstract class AppRepository {
  /// 本地用户与权限状态。下载/权限判定需要它，允许为空。
  LocalStore? access;

  /// 能力矩阵：UI 用它决定是否渲染入口，而不是点击后才报「不支持」。
  RepositoryCapabilities get capabilities => const RepositoryCapabilities();
  Future<Map<String, dynamic>> lan(
    String command,
    Map<String, dynamic> payload,
  ) async => throw AppFailure('当前环境不支持设备互联');
  Future<PlaybackPlan?> prepareHandoff(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => preload(drama, episode, quality: quality);
  Future<void> cancelHandoff() async {}
  Future<ResourceSettings> resourceSettings() async => const ResourceSettings();
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async => throw AppFailure('当前环境不支持资源设置');
  final catalogUpdates = CatalogUpdates();
  Future<void> cancelPreload() async {}
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async => null;
  Future<void> cancelDanmaku() async {}
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async => throw AppFailure('当前环境不支持弹幕');
  Future<void> cancelCatalog() async {}
  Future<void> cancelSuggestions() async {}
  Future<void> cancelRecommendations() async {}
  Future<Drama?> supplementMetadata(Drama drama) async => null;
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持红果推荐');
  Future<List<RankingBoard>> rankingBoards() async => const [];
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持榜单');
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory.all];
  bool get supportsSourceManagement => false;
  Future<SourceStatus> sourceStatus(String source) async =>
      SourceStatus.fromJson({'source': source});
  Future<SourceStatus> startSourceJob(
    String source,
    String operation, {
    Drama? drama,
  }) async => throw AppFailure('当前环境不支持站源管理');
  Future<SourceStatus> cancelSourceJob(String source) async =>
      throw AppFailure('当前环境不支持站源管理');
  Future<List<String>> suggestions(String query) async => const [];
  Future<Map<String, dynamic>> storage() async => {};
  Future<String> downloadDirectory() async =>
      (await storage())['directory'] as String? ?? '';
  Future<void> moveDownloads(String directory) async =>
      throw AppFailure('当前环境不支持迁移');
  Future<int> workLease(String id, String command) async => 0;
  bool get supportsDownloads => false;
  Future<List<DownloadJob>> downloads() async => [];
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async => throw AppFailure('当前环境不支持下载');
  Future<void> controlDownloads(String command, {String id = ''}) async {}
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids, {
    Map<String, String> expectedVersions = const {},
  }) async {
    if (expectedVersions.isNotEmpty) throw AppFailure('当前环境不支持校验后清理原分集');
    final completed = <String>[], failures = <String, String>{};
    for (final id in ids.toSet()) {
      try {
        await controlDownloads(command, id: id);
        completed.add(id);
      } catch (error) {
        failures[id] = error.toString();
      }
    }
    return DownloadBatchResult(completed: completed, failures: failures);
  }

  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) => enqueueDownloads(detail, episodes, quality: quality);
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async =>
      null;
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => resolve(drama, episode, quality: quality);
  Future<void> initialize();
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  });
  Future<CatalogPage> cached(String source, {String category = ''});
  Future<String> cover(Drama drama, {bool force = false});
  Future<DramaDetail> detail(Drama drama);
  Future<PlaybackPlan> resolve(Drama drama, Episode episode, {int quality = 0});
  Future<PlaybackPlan> fallback(PlaybackPlan current);
  Future<void> cancelPlayback();
  Future<void> release(String session);
}
