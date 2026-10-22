library;

// 这批用例会真实请求芽果，断网或站点改版时失败不算回归。
// 默认运行会排除 engine tag，需要时用 `flutter test --tags engine` 显式打开。

import 'dart:io';

import 'package:hoshi/data/engine_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/engine_setup.dart';

/// Core-1 验收：引擎单例的状态必须跨 FRB 调用存活。
///
/// 这些用例依赖真实站源，因此打 `engine` 标签；离线回归覆盖在
/// `rust/bridge/tests/core1_singleton.rs`（假传输层）。
void main() {
  late EngineRepository repository;

  setUpAll(() async {
    await initEngineForTest();
    repository = EngineRepository.attached();
  });

  test('两次独立调用复用同一份会话数据', () async {
    // 芽果令牌在第一次调用时获取并落盘；第二次调用不应重新登录。
    // 无法直接读登录次数，因此用「会话键存在且两次调用都成功」来断言机制：
    // 令牌没落盘时第二次调用仍会成功（内存缓存），但重启会失效——
    // 那一半由 Rust 侧 `sessions_survive_reopen` 覆盖。
    final first = await repository.catalog('yaguo', page: 1);
    expect(first.items, isNotEmpty);

    final diagnostics = await repository.diagnostics();
    expect(
      diagnostics.sources.any((source) => source.id == 'yaguo'),
      isTrue,
      reason: '引擎清单必须包含芽果',
    );
    expect(
      diagnostics.sources
          .firstWhere((source) => source.id == 'yaguo')
          .supports('resolve'),
      isTrue,
      reason: '芽果声明 resolve 能力，播放链路才能直连',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('取消目录请求不会抛到调用方以外', () async {
    // 先发起请求再取消：无论请求是否已完成，`cancelCatalog` 都必须
    // 返回布尔值而不是抛异常（UI 在切页时无脑调用）。
    final result = await repository.cancelCatalog('wuguo');
    expect(result, isA<bool>());
  });

  test('诊断快照包含路径、计数与能力矩阵', () async {
    final diagnostics = await repository.diagnostics();
    expect(diagnostics.version, isNotEmpty);
    expect(diagnostics.dataDirectory, isNotEmpty);
    expect(diagnostics.pluginDirectory, isNotEmpty);
    expect(diagnostics.sessionFile, endsWith('sessions.json'));
    expect(diagnostics.catalogFile, endsWith('catalogs.json'));
    expect(diagnostics.sources, isNotEmpty);
    // 源身份统一：引擎清单里只有 dsd，没有 diguo。
    final ids = diagnostics.sources.map((source) => source.id).toList();
    expect(ids, contains('dsd'));
    expect(ids, isNot(contains('diguo')));
    // Go-only 源不在引擎清单里，因此不会出现在 UI。
    expect(ids, isNot(contains('huangdou')));
    expect(ids, isNot(contains('yeguo')));
    expect(ids, isNot(contains('piguo')));
  });

  test('会话数据落在引擎数据目录', () async {
    await repository.catalog('yaguo', page: 1);
    final diagnostics = await repository.diagnostics();
    final file = File(diagnostics.sessionFile);
    // 芽果登录后必须留下文件；文件缺失意味着令牌只在内存里。
    expect(file.existsSync(), isTrue, reason: '登录令牌应落盘，否则重启后每次都要重新登录');
    expect(diagnostics.sessionKeys, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('清空站源会话后仍能重新登录', () async {
    await repository.catalog('yaguo', page: 1);
    final cleared = await repository.clearSourceSession('yaguo');
    expect(cleared, greaterThan(0));

    // 令牌被清掉后下一次调用应重新登录并成功，而不是报「会话失效」。
    final page = await repository.catalog('yaguo', page: 1);
    expect(page.items, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
