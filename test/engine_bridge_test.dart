import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/src/rust/api.dart';
import 'package:duanju_app/src/rust/frb_generated.dart';

/// 验证 Rust 引擎已接入且可被 Dart 真实调用。
///
/// 这是「替换 Go 核心」的第一个可执行里程碑：
/// 引擎在 Flutter 进程内被加载、初始化和调用。
void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('engine reports a version', () async {
    final version = await engineVersion();
    expect(version, isNotEmpty);
  });

  test('engine exposes builtin source catalog', () async {
    final sources = await sourceCatalog();
    expect(sources, isNotEmpty);
    final maoguo = sources.firstWhere((site) => site.id == 'maoguo');
    expect(maoguo.name, '猫果');
    expect(maoguo.apiLevel, greaterThanOrEqualTo(1));
    expect(maoguo.capabilities, contains('catalog'));
  });

  test('declarative rule parses a catalog page', () async {
    final rule = await _readFixture('engine/rules/wuguo.json');
    final html = await _readFixture(
      'engine/bridge/tests/fixtures/wuguo_catalog.html',
    );
    final page = await parseCatalogWithRule(
      ruleJson: rule,
      html: html,
      page: 1,
    );
    expect(page.items.length, greaterThanOrEqualTo(20));
    final first = page.items.first;
    expect(first.source, 'wuguo');
    expect(first.id, startsWith('wuguo:'));
    expect(first.title, isNotEmpty);
    expect(first.title.contains('人在追'), isFalse);
  });

  test('declarative rule parses chapters', () async {
    final rule = await _readFixture('engine/rules/wuguo.json');
    final html = await _readFixture(
      'engine/bridge/tests/fixtures/wuguo_detail.html',
    );
    final chapters = await parseDetailWithRule(
      ruleJson: rule,
      html: html,
      drama: DramaInput(
        id: 'wuguo:100',
        source: 'wuguo',
        sourceId: '100',
        title: '样本',
      ),
    );
    expect(chapters, isNotEmpty);
    expect(chapters.first.title, isNotEmpty);
    expect(chapters.first.pageUrl, startsWith('http'));
  });

  test('invalid rule is rejected with a message', () async {
    await expectLater(validateRule(ruleJson: "{"), throwsA(isA<Object>()));
  });

  test('valid rule returns its id', () async {
    final rule = await _readFixture('engine/rules/wuguo.json');
    expect(await validateRule(ruleJson: rule), 'wuguo');
  });
}

Future<String> _readFixture(String relativePath) async {
  final candidates = [relativePath, '../$relativePath', '../../$relativePath'];
  for (final candidate in candidates) {
    final file = File(candidate);
    if (file.existsSync()) {
      return file.readAsString();
    }
  }
  throw StateError(
    'fixture not found: $relativePath (cwd=${Directory.current.path})',
  );
}
