/// 构建变体开关：`ALL_SOURCES` 决定**编译进哪些站源**（iOS 全源，
/// Android / Windows / macOS 只带内置站源）。应用名不再随开关变化。
const allSourcesEnabled = bool.fromEnvironment('ALL_SOURCES');

/// 应用显示名（窗口标题、通知、UI 文案统一引用）。
const appName = '星';

/// 应用标识（备份/导出文件名等内部用途），不再随构建变体变化。
const appSlug = 'hoshi';
