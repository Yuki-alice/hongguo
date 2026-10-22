library;

import 'dart:io';
import '../support/engine_setup.dart';

import 'package:duanju_app/data/engine_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实下载验证：从站源取流后下载到临时目录。
void main() {
  late EngineRepository repository;
  late Directory workdir;

  setUpAll(() async {
    await initEngineForTest();
    repository = EngineRepository(initialized: true);
    workdir = Directory.systemTemp.createTempSync('guo-dl-dart');
  });

  tearDownAll(() {
    if (workdir.existsSync()) workdir.deleteSync(recursive: true);
  });

  test('enqueue + run downloads a real media file', () async {
    final page = await repository.catalog('maoguo', category: '0');
    final target = page.items.first;
    final detail = await repository.detail(target);
    final episode = detail.episodes.first;
    final plan = await repository.resolve(target, episode);

    final path = '${workdir.path}/episode1';
    final bytes = await repository.download(
      id: 'dl-1',
      url: plan.url,
      target: path,
      referer: plan.headers['Referer'] ?? '',
      title: episode.title,
    );

    expect(bytes, greaterThan(0));
    final file = File(path);
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), bytes);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('snapshot reflects the completed job', () async {
    final rows = await repository.downloads();
    expect(rows, isNotEmpty);
    final job = rows.firstWhere((row) => row.id == 'dl-1');
    expect(job.state, 'completed');
    expect(job.bytes, greaterThan(0));
    expect(job.progress, closeTo(1.0, 0.001));
    expect(job.finished, isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('control delete removes the job from the snapshot', () async {
    expect(await repository.controlDownload('delete', 'dl-1'), isTrue);
    final rows = await repository.downloads();
    expect(rows.any((row) => row.id == 'dl-1'), isFalse);
  });

  test('unknown job id fails loudly', () async {
    await expectLater(
      repository.download(
        id: 'missing',
        url: 'https://cdn.test/none.mp4',
        target: '${workdir.path}/missing',
        referer: '',
        title: 'x',
      ),
      throwsA(isA<Object>()),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
