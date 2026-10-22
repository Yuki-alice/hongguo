import 'package:hoshi/data/core_bridge.dart';
import 'package:hoshi/data/media/media_library.dart';
import 'package:hoshi/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadJob _job(
  int number, {
  String state = 'completed',
  String dramaId = 'hongguo:100',
}) => DownloadJob(
  id: '$number',
  drama: Drama(id: dramaId, source: 'hongguo', title: '合并测试剧'),
  episode: Episode({'currentEpisode': number}, number),
  state: state,
);

void main() {
  test('有效分集按集数排序', () {
    final jobs = continuousMergeJobs([_job(3), _job(1), _job(2)]);

    expect(jobs.map((job) => job.episode.number), [1, 2, 3]);
  });

  test('未完成分集被拒绝', () {
    expect(
      () => continuousMergeJobs([_job(1), _job(2, state: 'downloading')]),
      throwsA(isA<AppFailure>()),
    );
  });

  test('不同剧集不能合并', () {
    expect(
      () => continuousMergeJobs([_job(1), _job(2, dramaId: 'hongguo:200')]),
      throwsA(isA<AppFailure>()),
    );
  });

  test('重复集数被拒绝', () {
    expect(
      () => continuousMergeJobs([_job(1), _job(1)]),
      throwsA(isA<AppFailure>()),
    );
  });

  test('缺少中间集数时报告缺口', () {
    expect(
      () => continuousMergeJobs([_job(1), _job(4)]),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.message,
          'message',
          contains('缺少第 2、3 集'),
        ),
      ),
    );
    expect(() => continuousMergeJobs([_job(1)]), throwsA(isA<AppFailure>()));
  });
}
