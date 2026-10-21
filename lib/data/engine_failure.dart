import 'package:duanju_app/src/rust/api/error.dart' as rust_error;

/// 失败类别。与 Rust 侧 `EngineFailure.kind` 的字符串一一对应。
///
/// UI 按类别决定处理方式：可重试的给「重试」、风控的显示倒计时、
/// 不支持的直接隐藏入口，而不是统一弹一句「读取失败」。
enum EngineFailureKind {
  unsupported,
  network,
  timeout,
  http,
  parseChanged,
  session,
  blocked,
  cancelled,
  storage,
  plugin,
  internal;

  static EngineFailureKind parse(String raw) => switch (raw) {
    'unsupported' => unsupported,
    'network' => network,
    'timeout' => timeout,
    'http' => http,
    'parse_changed' => parseChanged,
    'session' => session,
    'blocked' => blocked,
    'cancelled' => cancelled,
    'storage' => storage,
    'plugin' => plugin,
    _ => internal,
  };
}

/// 引擎失败在 Dart 侧的表示。
///
/// 取代原先「捕获任意异常再回退」的写法：调用方按 `kind` 与 `retryable`
/// 决定重试、退避、换源还是隐藏，不再解析中文文案。
class EngineException implements Exception {
  EngineException({
    required this.kind,
    required this.message,
    this.sourceId = '',
    this.requestId = '',
    this.retryable = false,
    this.httpStatus = 0,
    this.retryAtMs = 0,
  });

  final EngineFailureKind kind;
  final String message;

  /// 出错站源；与站源无关时为空。
  final String sourceId;

  /// 调用方发出的请求标识，用于丢弃过期回调。
  final String requestId;

  /// 是否值得原样重试。
  final bool retryable;

  /// HTTP 状态码；非 HTTP 错误为 0。
  final int httpStatus;

  /// 风控解除时间（Unix 毫秒）；仅 [EngineFailureKind.blocked] 有意义。
  final int retryAtMs;

  /// 是否因为调用方主动取消（UI 应当静默丢弃，不提示）。
  bool get isCancelled => kind == EngineFailureKind.cancelled;

  /// 是否属于「该入口不该出现」的情形，UI 应隐藏对应按钮。
  bool get isUnsupported => kind == EngineFailureKind.unsupported;

  /// 风控剩余时间。非风控错误或已过期返回 `Duration.zero`。
  Duration get retryAfter {
    if (retryAtMs == 0) return Duration.zero;
    final left = retryAtMs - DateTime.now().millisecondsSinceEpoch;
    return left > 0 ? Duration(milliseconds: left) : Duration.zero;
  }

  /// 从 FRB 的 `EngineFailure` 转换。
  factory EngineException.fromRust(rust_error.EngineFailure failure) => EngineException(
    kind: EngineFailureKind.parse(failure.kind),
    message: failure.message,
    sourceId: failure.sourceId,
    requestId: failure.requestId,
    retryable: failure.retryable,
    httpStatus: failure.httpStatus,
    retryAtMs: failure.retryAtMs.toInt(),
  );

  /// 把任意异常归一为引擎异常。
  ///
  /// 已经是 [EngineException] 时原样返回；FRB 会把 Rust 错误重新抛出，
  /// 因此这里也要处理 `AnyhowException` 一类只有文案的兜底。
  static EngineException from(Object error) {
    if (error is EngineException) return error;
    if (error is rust_error.EngineFailure) return EngineException.fromRust(error);
    return EngineException(
      kind: EngineFailureKind.internal,
      message: error.toString(),
    );
  }

  @override
  String toString() => message;
}
