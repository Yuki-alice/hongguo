/// Material Design 3 设计令牌。
///
/// 只放数值与常量，不含任何业务逻辑；主题、页面和组件都从这里取值，
/// 避免各页面私自定义间距、圆角和动效时长。
library;

import 'package:flutter/material.dart';

/// 8dp 间距系统（M3 Expressive 规范）。
abstract final class Md3Spacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
  static const double huge = 64;

  /// 页面级左右留白：紧凑窗口 16，展开窗口 24。
  static double pageInset(double width) =>
      width >= Md3WindowClass.medium ? xl : lg;

  /// 大窗口内容最大宽度，避免长行不可读。
  static const double contentMaxWidth = 1040;

  /// 条目之间的标准间距。
  static const double listGap = md;

  /// 网格间距随窗口宽度变化。
  static double gridGap(double width) =>
      width >= Md3WindowClass.expanded ? lg : md;
}

/// M3 窗口尺寸等级。
abstract final class Md3WindowClass {
  static const double compact = 0;
  static const double medium = 600;
  static const double expanded = 840;
  static const double large = 1200;
  static const double extraLarge = 1600;

  /// 依据宽度返回窗口等级名称，供布局分支使用。
  static Md3WindowSize of(double width) {
    if (width >= extraLarge) return Md3WindowSize.extraLarge;
    if (width >= large) return Md3WindowSize.large;
    if (width >= expanded) return Md3WindowSize.expanded;
    if (width >= medium) return Md3WindowSize.medium;
    return Md3WindowSize.compact;
  }

  /// 是否需要常驻导航栏（而非底部导航）。
  static bool usesRail(double width) => width >= expanded;

  /// 是否需要双栏主从布局。
  static bool usesTwoPane(double width) => width >= expanded;

  /// 是否限制内容宽度。
  static bool constrainsContent(double width) => width >= large;
}

enum Md3WindowSize { compact, medium, expanded, large, extraLarge }

/// M3 形状令牌。数值取自规范，避免各处写字面量。
abstract final class Md3Shape {
  static const double none = 0;
  static const double extraSmall = 4;
  static const double small = 8;
  static const double medium = 12;
  static const double large = 16;
  static const double largeIncreased = 20;
  static const double extraLarge = 28;
  static const double extraLargeIncreased = 32;
  static const double extraExtraLarge = 48;
  static const double full = 999;

  static final BorderRadius card = BorderRadius.circular(medium);

  static final BorderRadius chip = BorderRadius.circular(small);

  static final BorderRadius dialog = BorderRadius.circular(extraLarge);

  static final BorderRadius sheet = BorderRadius.circular(extraLarge);

  static final BorderRadius field = BorderRadius.circular(extraSmall);

  static final BorderRadius largeRadius = BorderRadius.circular(large);

  static final BorderRadius pill = BorderRadius.circular(full);
}

/// M3 动效令牌：Expressive 用弹簧，转场用缓动曲线。
abstract final class Md3Motion {
  static const Duration emphasized = Duration(milliseconds: 500);
  static const Duration emphasizedDecelerate = Duration(milliseconds: 400);
  static const Duration emphasizedAccelerate = Duration(milliseconds: 200);
  static const Duration standard = Duration(milliseconds: 300);
  static const Duration standardDecelerate = Duration(milliseconds: 250);
  static const Duration standardAccelerate = Duration(milliseconds: 200);

  static const Curve emphasizedCurve = Cubic(.2, 0, 0, 1);
  static const Curve emphasizedDecelerateCurve = Cubic(.05, .7, .1, 1);
  static const Curve emphasizedAccelerateCurve = Cubic(.3, 0, .8, .15);
  static const Curve standardCurve = Cubic(.2, 0, 0, 1);

  /// 组件级状态变化（选中、展开）使用的轻量弹簧，避免生硬跳变。
  static const SpringDescription expressiveSpring = SpringDescription(
    mass: 1,
    stiffness: 380,
    damping: 32,
  );
}

/// 语义色配对的便捷读取，保证不做任意前后景搭配。
extension Md3ColorRoles on ColorScheme {
  /// 容器表面 + 对应前景，用于卡片、面板。
  (Color background, Color foreground) get containerPair =>
      (surfaceContainerLow, onSurface);

  /// 强调容器 + 对应前景，用于选中态、徽标。
  (Color background, Color foreground) get accentPair =>
      (primaryContainer, onPrimaryContainer);

  /// 次级强调，用于弱化按钮与标签。
  (Color background, Color foreground) get secondaryPair =>
      (secondaryContainer, onSecondaryContainer);
}
