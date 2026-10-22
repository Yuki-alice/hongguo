import 'package:duanju_app/data/engine_failure.dart';

/// 仓库的能力矩阵。
///
/// UI 在渲染前查询，避免「先把按钮画出来，点下去才报不支持」。每一项都要
/// 如实反映当前实现状态：能力一旦接入就改成 `true`，而不是提前打开入口。
class RepositoryCapabilities {
  const RepositoryCapabilities({
    this.sourceManagement = false,
    this.downloads = false,
    this.danmaku = false,
    this.recommendations = false,
    this.rankings = false,
    this.suggestions = false,
    this.resourceSettings = false,
    this.localPlayback = false,
    this.lan = false,
  });

  /// 站源诊断 / 健康检查 / 修复。
  final bool sourceManagement;

  /// 下载与离线播放。
  final bool downloads;

  /// 弹幕。按站源能力位判断，这里只表示引擎侧是否具备该通道。
  final bool danmaku;

  /// 红果推荐流。
  final bool recommendations;

  /// 榜单。
  final bool rankings;

  /// 搜索联想。
  final bool suggestions;

  /// 代理 / DNS / CDN 等资源设置。首发仅直连。
  final bool resourceSettings;

  /// 本地文件播放（已下载分集）。
  final bool localPlayback;

  /// 局域网设备互联。当前阶段明确不提供。
  final bool lan;
}

/// 未实现 / 不支持的显式失败。
///
/// 与「网络失败」区分开：UI 对前者隐藏入口，对后者提示重试。
class UnsupportedFailure extends EngineException {
  UnsupportedFailure(String capability)
    : super(kind: EngineFailureKind.unsupported, message: '当前版本不支持$capability');
}

/// 把失败翻译成可展示文案。
///
/// 只处理展示；重试策略应由调用方按 [EngineFailureKind] 决定，不要在这里
/// 混入「哪些错误值得重试」的隐含约定。
String describeFailure(Object error) {
  final failure = error is EngineException
      ? error
      : EngineException.from(error);
  return switch (failure.kind) {
    EngineFailureKind.network => '网络连接失败，请检查网络后重试',
    EngineFailureKind.timeout => '站源响应超时，请重试',
    EngineFailureKind.http when failure.httpStatus >= 500 => '站源暂时不可用，请稍后重试',
    EngineFailureKind.http => '站源返回错误（HTTP ${failure.httpStatus}）',
    EngineFailureKind.parseChanged => failure.message,
    EngineFailureKind.session => '登录状态已失效，请重试',
    EngineFailureKind.blocked => '站源访问受限，请稍后重试',
    EngineFailureKind.cancelled => '请求已取消',
    EngineFailureKind.storage => '本地存储读写失败',
    EngineFailureKind.plugin => failure.message,
    EngineFailureKind.unsupported => failure.message,
    EngineFailureKind.internal => '读取失败，请重试',
  };
}
