import 'package:flutter/foundation.dart';

/// 桌面窗口边界。
///
/// 只用于「记住上次的位置与大小」，不做布局计算。读取时如果坐标落在
/// 不存在的显示器上，调用方应放弃位置、只保留尺寸（见 `DesktopWindow`）。
@immutable
class WindowBounds {
  const WindowBounds({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  factory WindowBounds.fromJson(Map<String, dynamic> json) => WindowBounds(
    left: (json['left'] as num).toDouble(),
    top: (json['top'] as num).toDouble(),
    width: (json['width'] as num).toDouble(),
    height: (json['height'] as num).toDouble(),
  );

  Map<String, dynamic> toJson() => {
    'left': left,
    'top': top,
    'width': width,
    'height': height,
  };

  @override
  bool operator ==(Object other) =>
      other is WindowBounds &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() => 'WindowBounds($left, $top, $width×$height)';
}

/// 关闭窗口时的行为。
enum CloseBehavior {
  /// 直接退出应用。
  exit,

  /// 隐藏窗口，应用留在托盘里。
  minimizeToTray,

  /// 每次弹窗询问。
  ask,
}
