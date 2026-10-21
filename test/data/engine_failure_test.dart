import 'package:duanju_app/data/engine_failure.dart';
import 'package:duanju_app/data/engine_repository.dart';
import 'package:duanju_app/data/repository_capabilities.dart';
import 'package:duanju_app/src/rust/api/error.dart' as rust_error;
import 'package:flutter_test/flutter_test.dart';

/// `EngineException` 的分级映射：UI 按 `kind` / `retryable` 决定重试、
/// 退避还是隐藏入口，因此这些判定必须有确定行为。
void main() {
  EngineException fromRust({
    String kind = 'internal',
    String message = 'boom',
    bool retryable = false,
    int httpStatus = 0,
    int retryAtMs = 0,
    String sourceId = '',
    String requestId = '',
  }) => EngineException.fromRust(
    rust_error.EngineFailure(
      kind: kind,
      message: message,
      sourceId: sourceId,
      requestId: requestId,
      retryable: retryable,
      httpStatus: httpStatus,
      retryAtMs: BigInt.from(retryAtMs),
    ),
  );

  group('kind 解析', () {
    test('每种类别的线上字符串都能识别', () {
      const pairs = {
        'unsupported': EngineFailureKind.unsupported,
        'network': EngineFailureKind.network,
        'timeout': EngineFailureKind.timeout,
        'http': EngineFailureKind.http,
        'parse_changed': EngineFailureKind.parseChanged,
        'session': EngineFailureKind.session,
        'blocked': EngineFailureKind.blocked,
        'cancelled': EngineFailureKind.cancelled,
        'storage': EngineFailureKind.storage,
        'plugin': EngineFailureKind.plugin,
        'internal': EngineFailureKind.internal,
      };
      pairs.forEach((wire, expected) {
        expect(EngineFailureKind.parse(wire), expected, reason: wire);
      });
    });

    test('未知类别归为 internal，不抛异常', () {
      expect(EngineFailureKind.parse('future_kind'), EngineFailureKind.internal);
    });
  });

  group('从 Rust 错误转换', () {
    test('保留类别、来源、请求号与状态码', () {
      final failure = fromRust(
        kind: 'http',
        message: '站源返回 HTTP 503',
        retryable: true,
        httpStatus: 503,
        sourceId: 'wuguo',
        requestId: 'req-7',
      );
      expect(failure.kind, EngineFailureKind.http);
      expect(failure.retryable, isTrue);
      expect(failure.httpStatus, 503);
      expect(failure.sourceId, 'wuguo');
      expect(failure.requestId, 'req-7');
    });

    test('不支持与取消有专用判定', () {
      expect(fromRust(kind: 'unsupported').isUnsupported, isTrue);
      expect(fromRust(kind: 'cancelled').isCancelled, isTrue);
      expect(fromRust(kind: 'network').isCancelled, isFalse);
      expect(fromRust(kind: 'network').isUnsupported, isFalse);
    });

    test('风控倒计时按剩余时间计算', () {
      final future = DateTime.now().millisecondsSinceEpoch + 30000;
      final failure = fromRust(kind: 'blocked', retryAtMs: future);
      expect(failure.retryAfter.inSeconds, greaterThan(25));
      expect(failure.retryAfter.inSeconds, lessThanOrEqualTo(30));
    });

    test('已过期的风控时间返回 0', () {
      final past = DateTime.now().millisecondsSinceEpoch - 1000;
      expect(fromRust(kind: 'blocked', retryAtMs: past).retryAfter, Duration.zero);
      expect(fromRust(kind: 'blocked').retryAfter, Duration.zero);
    });
  });

  group('归一化', () {
    test('已是 EngineException 时原样返回', () {
      final original = fromRust(kind: 'network');
      expect(identical(EngineException.from(original), original), isTrue);
    });

    test('普通异常归为 internal 并保留文案', () {
      final failure = EngineException.from(StateError('本地错误'));
      expect(failure.kind, EngineFailureKind.internal);
      expect(failure.message, contains('本地错误'));
    });

    test('toString 只输出可读文案', () {
      expect(fromRust(message: '读取失败').toString(), '读取失败');
    });
  });

  group('展示文案', () {
    test('可重试类别给出重试指引', () {
      expect(describeFailure(fromRust(kind: 'network')), contains('重试'));
      expect(describeFailure(fromRust(kind: 'timeout')), contains('重试'));
    });

    test('5xx 与 4xx 文案不同', () {
      final server = describeFailure(
        fromRust(kind: 'http', httpStatus: 503),
      );
      final client = describeFailure(fromRust(kind: 'http', httpStatus: 404));
      expect(server, contains('稍后重试'));
      expect(client, contains('404'));
    });

    test('不支持直接透传引擎说明', () {
      expect(
        describeFailure(fromRust(kind: 'unsupported', message: '不支持弹幕')),
        '不支持弹幕',
      );
    });
  });

  group('能力矩阵', () {
    test('默认全部关闭，避免误开入口', () {
      const matrix = RepositoryCapabilities();
      expect(matrix.sourceManagement, isFalse);
      expect(matrix.downloads, isFalse);
      expect(matrix.lan, isFalse);
      expect(matrix.resourceSettings, isFalse);
    });
  });

  test('UnsupportedFailure 归类为 unsupported 且带能力名', () {
    final failure = UnsupportedFailure('设备互联');
    expect(failure.kind, EngineFailureKind.unsupported);
    expect(failure.message, contains('设备互联'));
    expect(failure.retryable, isFalse);
  });

  test('引擎诊断视图能按能力位查询站源', () {
    const source = SourceCapabilityInfo(
      id: 'hongguo',
      name: '红果',
      group: 'duanju',
      apiLevel: 1,
      capabilities: ['catalog', 'danmaku'],
    );
    expect(source.supports('danmaku'), isTrue);
    expect(source.supports('resolve'), isFalse);
  });
}
