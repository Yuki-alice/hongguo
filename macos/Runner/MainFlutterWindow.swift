import Cocoa
import FlutterMacOS

/// 主窗口。
///
/// 隐藏系统标题栏，让 Flutter 内容延伸到窗口顶部：交通灯按钮仍然由系统
/// 绘制并浮在内容上，Flutter 侧只需把交互控件让开（见 `NativeInset`）。
///
/// 同时把窗口设成「全尺寸内容视图」，否则内容会被自动压到标题栏下方，
/// 顶部 22px 会留一条空白。
class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // 沉浸式标题栏：隐藏系统标题栏，交通灯悬浮。
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)
    // 顶部保留一条细边，让拖动区域有视觉落点；实际拖拽由 Flutter 侧
    // `DragArea` 通过 window_manager.startDragging() 交给系统处理。
    self.isMovableByWindowBackground = false

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
