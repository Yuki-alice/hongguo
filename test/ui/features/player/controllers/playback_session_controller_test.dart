import 'package:hoshi/domain/models.dart';
import 'package:hoshi/ui/features/player/controllers/playback_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('begin 递增票据并重置加载状态', () {
    final controller = PlaybackSessionController(index: 1, quality: 720);
    controller.setForceOnline(true);
    controller.fail(message: '旧错误', localFailure: true);
    var notifications = 0;
    controller.addListener(() => notifications++);

    final ticket = controller.begin(
      index: 0,
      message: '正在重新获取播放地址',
      showControlsOnReady: false,
    );

    expect(ticket, 1);
    expect(controller.generation, 1);
    expect(controller.index, 0);
    expect(controller.loading, isTrue);
    expect(controller.error, isNull);
    expect(controller.localFailure, isFalse);
    expect(controller.forceOnline, isFalse);
    expect(controller.loadingMessage, '正在重新获取播放地址');
    expect(controller.showControlsOnPlaybackReady, isFalse);
    expect(notifications, 1);
  });

  test('同一集重新加载保留手动在线标记', () {
    final controller = PlaybackSessionController(index: 2, quality: 0);
    controller.setForceOnline(true);

    controller.begin(index: 2, message: '正在准备播放', showControlsOnReady: true);

    expect(controller.forceOnline, isTrue);
  });

  test('finish 安装播放计划并结束加载', () {
    final controller = PlaybackSessionController(index: 0, quality: 0);
    final plan = const PlaybackPlan(
      url: 'https://example.test/local.mp4',
      session: 'session-1',
      local: true,
    );
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.finish(plan: plan, index: 1);

    expect(controller.loading, isFalse);
    expect(controller.plan, same(plan));
    expect(controller.session, 'session-1');
    expect(controller.index, 1);
    expect(controller.qualityLabel, '本地原画');
    expect(notifications, 1);
  });

  test('fail 记录错误与本地失败标记', () {
    final controller = PlaybackSessionController(index: 0, quality: 0);

    controller.fail(message: '无法播放', localFailure: true);

    expect(controller.loading, isFalse);
    expect(controller.error, '无法播放');
    expect(controller.localFailure, isTrue);
    expect(controller.ready, isFalse);
  });

  test('清晰度与在线标记只在变化时通知', () {
    final controller = PlaybackSessionController(index: 0, quality: 0);
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.setRequestedQuality(720);
    controller.setRequestedQuality(720);
    controller.setForceOnline(true);
    controller.setForceOnline(true);

    expect(controller.requestedQuality, 720);
    expect(controller.forceOnline, isTrue);
    expect(controller.qualityLabel, '720P');
    expect(notifications, 2);
  });

  test('invalidate 让进行中的票据失效', () {
    final controller = PlaybackSessionController(index: 0, quality: 0);
    final ticket = controller.begin(
      index: 1,
      message: '正在准备播放',
      showControlsOnReady: true,
    );

    controller.invalidate();

    expect(controller.generation, ticket + 1);
  });
}
