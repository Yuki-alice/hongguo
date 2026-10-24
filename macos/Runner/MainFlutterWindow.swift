import Cocoa
import FlutterMacOS

/// 主窗口。
///
/// 刻意不动 `styleMask`：隐藏标题栏交给 `window_manager` 的
/// `TitleBarStyle.hidden`（见 `DesktopWindow`）。
///
/// 约束：不要再给窗口加 `.fullSizeContentView`。它会让系统把
/// `MediaQuery.padding.top` 报成 0，全应用的 `SafeArea` 随之失效，
/// 红绿灯直接压住标题。位置让开由 `WindowSafeArea` 统一处理。
class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
