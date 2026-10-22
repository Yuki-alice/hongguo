library;

import 'dart:io';

import 'package:hoshi/data/engine_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/engine_setup.dart';

void main() {
  late EngineRepository engine;
  setUpAll(() async {
    await initEngineForTest();
    engine = EngineRepository.attached();
  });

  test('封面下载到本地并命中缓存', () async {
    final page = await engine.catalog('maoguo', category: '0');
    final drama = page.items.firstWhere((item) => item.cover.isNotEmpty);
    final first = await engine.cover(drama);
    expect(File(first.path).existsSync(), isTrue, reason: '封面应落盘');
    expect(File(first.path).lengthSync(), greaterThan(100));

    final second = await engine.cover(drama);
    expect(second.cached, isTrue, reason: '第二次必须命中缓存');
    expect(second.path, first.path);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('force 会重新下载', () async {
    final page = await engine.catalog('maoguo', category: '0');
    final drama = page.items.firstWhere((item) => item.cover.isNotEmpty);
    await engine.cover(drama);
    final forced = await engine.cover(drama, force: true);
    expect(forced.cached, isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('清空缓存后重新下载', () async {
    final page = await engine.catalog('maoguo', category: '0');
    final drama = page.items.firstWhere((item) => item.cover.isNotEmpty);
    await engine.cover(drama);
    final removed = await engine.clearCoverCache();
    expect(removed, greaterThan(0));
    final again = await engine.cover(drama);
    expect(again.cached, isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
