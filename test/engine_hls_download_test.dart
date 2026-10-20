import 'dart:io';

import 'package:duanju_app/data/engine_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// 加密 HLS 的端到端下载验证。
void main() {
  late EngineRepository repository;
  late Directory workdir;

  setUpAll(() async {
    repository = await EngineRepository.create();
    workdir = Directory.systemTemp.createTempSync('guo-hls-dart');
  });

  tearDownAll(() {
    try {
      if (workdir.existsSync()) workdir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上引擎可能仍持有分片句柄，临时目录由系统回收即可。
    }
  });

  test('resolve exposes HLS segments and key material', () async {
    final page = await repository.catalog('maoguo', category: '0');
    final drama = page.items.first;
    final detail = await repository.detail(drama);
    final plan = await repository.resolve(drama, detail.episodes.first);

    expect(plan.segments, isNotEmpty, reason: '应识别出 HLS 分片');
    expect(plan.keyUri, isNotEmpty, reason: '猫果使用 AES-128 加密');
    expect(plan.keyIv, isNotEmpty, reason: '播放列表声明了 IV');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('downloads and decrypts an encrypted HLS stream', () async {
    final page = await repository.catalog('maoguo', category: '0');
    final drama = page.items.first;
    final detail = await repository.detail(drama);
    final episode = detail.episodes.first;
    final plan = await repository.resolve(drama, episode);

    final path = '${workdir.path}/hls-ep1';
    final bytes = await repository.download(
      id: 'hls-1',
      url: plan.url,
      target: path,
      referer: plan.headers['Referer'] ?? '',
      title: episode.title,
      segments: plan.segments,
      keyUri: plan.keyUri,
      keyIv: plan.keyIv,
    );

    expect(bytes, greaterThan(100000), reason: '应下载完整视频');

    final file = File(path);
    expect(file.existsSync(), isTrue);
    final head = file.openSync().readSync(8);
    // 解密成功的 MPEG-TS 以 0x47 同步字节开头。
    expect(head.first, 0x47, reason: '解密后应为 MPEG-TS，实际首字节 ${head.first}');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
