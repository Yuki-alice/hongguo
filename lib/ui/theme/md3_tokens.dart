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

  /// 页面级左右留白：随窗口宽度增长，大窗口不再贴边。
  static double pageInset(double width) => switch (Md3WindowClass.of(width)) {
    Md3WindowSize.compact || Md3WindowSize.medium => lg,
    Md3WindowSize.expanded => xl,
    Md3WindowSize.large || Md3WindowSize.extraLarge => xxl,
  };

  /// 内容最大宽度。
  ///
  /// 单栏文本 / 表单 / 设置面板用 [contentMaxWidth]；需要铺满的媒体网格
  /// 用 [wideMaxWidth]。超过这个宽度后左右留白继续增长，内容不再拉伸。
  static const double contentMaxWidth = 1040;

  /// 媒体网格类页面的最大宽度。
  static const double wideMaxWidth = 1440;

  /// 「我的」页 bento 磁贴区的最大宽度（参照应用 `my_space_view`）。
  static const double bentoMaxWidth = 1120;

  /// 让内容在 [maxWidth] 内居中所需的左右留白。
  ///
  /// 留白取「页面标准留白」与「居中所需留白」的较大值：窗口窄时用标准
  /// 留白，窗口很宽时留白继续增长，内容宽度停在 [maxWidth]。
  /// 这样网格不会在 2560 宽下被拉成一整排，也不需要额外的容器层级。
  static double contentInset(double width, {double? maxWidth}) {
    final standard = pageInset(width);
    if (maxWidth == null) return standard;
    final centered = (width - maxWidth) / 2;
    return centered > standard ? centered : standard;
  }

  /// 侧栏展开宽度。
  static const double sidebarWidth = 240;

  /// 侧栏收起（纯图标）宽度。
  static const double railWidth = 72;

  /// 设置面板左侧分组栏宽度。
  static const double settingsPaneWidth = 280;

  /// 详情页左栏宽度。
  static const double detailPaneWidth = 360;
}

/// 海报网格：列数与间距的唯一真相。
///
/// 数值照抄 Kazumi——`StyleString.cardSpace = 8`、`mainAxisSpacing =
/// cardSpace - 2`、海报比例 `0.65`（10:16，不是 2:3）、文字区预留
/// `textScaler.scale(32)`，列数按 600 / 840 两个断点给 3 / 5 / 6。
/// 也就是说卡片尺寸**随窗口变大**，而不是锁一个目标宽度：这是 Kazumi
/// 首页看起来「松弛、海报优先」的原因。
abstract final class Md3Grid {
  /// 海报宽高比（宽 / 高）。
  static const double posterRatio = 0.65;

  /// 列间距（Kazumi `StyleString.cardSpace`）。
  static const double spacing = Md3Spacing.sm;

  /// 行间距（Kazumi 的 `cardSpace - 2`）。
  ///
  /// 行比列更紧，因为卡片自带的文字块已经把行与行之间的视觉间隔撑开了。
  static const double rowSpacing = 6;

  /// 标题区预留高度，实际会再过一层 `TextScaler`。
  static const double textReserve = 32;

  static const int minColumns = 3;
  static const int maxColumns = 8;

  /// 给定内容宽度返回列数。
  ///
  /// [width] 必须是**已扣除页面留白**的内容宽度（见 [Md3Spacing.contentInset]）。
  /// Kazumi 用的是窗口宽度，我们多扣一层留白，于是 2560 宽下内容仍被
  /// [Md3Spacing.wideMaxWidth] 兜住，海报不会被拉到 400px。
  /// [min] / [max] 供电视等场景收紧。
  static int columns(
    double width, {
    int min = minColumns,
    int max = maxColumns,
  }) {
    final count = width > Md3WindowClass.expanded
        ? 6
        : width > Md3WindowClass.medium
        ? 5
        : minColumns;
    return count.clamp(min, max);
  }

  /// [columns] 列下单张卡片的宽度。
  static double tileWidth(double width, int columns) =>
      (width - (columns - 1) * spacing) / columns;
}

/// 窗口尺寸等级。
///
/// 只有**两档导航形态**：小于 [navigation] 用底部导航，大于等于则用侧栏。
/// 侧栏本身还有展开 / 收起两态（见 [sidebarExpanded]），但那是同一个
/// 形态内的变化，不是第三种形态。
///
/// 刻意不按设备类型分支：Flutter 应用跑在可调整大小的窗口里，平板分屏、
/// 桌面小窗、手机横屏都可能是同一个宽度。唯一按设备判断的是窗口 chrome
/// （是否自绘标题栏），它不影响任何布局。
abstract final class Md3WindowClass {
  static const double compact = 0;

  /// 导航形态切换点：底部导航 → 侧栏。
  static const double medium = 600;

  /// 布局升级点：内容可以使用双栏 / 更宽的网格。
  static const double expanded = 840;

  static const double large = 1200;
  static const double extraLarge = 1600;

  /// 侧栏默认展开的最小宽度。
  ///
  /// 低于它时侧栏收起为图标轨，需要展开时以浮层盖在内容上——600–900
  /// 这段宽度如果常驻 240px 侧栏，内容区会被压到 360 左右。
  static const double sidebarExpanded = 900;

  /// 窗口最小可用宽度。再窄时布局会开始互相挤压。
  static const double minimumWindow = 480;

  /// 依据宽度返回窗口等级名称，供布局分支使用。
  static Md3WindowSize of(double width) {
    if (width >= extraLarge) return Md3WindowSize.extraLarge;
    if (width >= large) return Md3WindowSize.large;
    if (width >= expanded) return Md3WindowSize.expanded;
    if (width >= medium) return Md3WindowSize.medium;
    return Md3WindowSize.compact;
  }

  /// 是否使用侧栏（而非底部导航）。
  static bool usesRail(double width) => width >= medium;

  /// 侧栏是否需要常驻展开（否则收起为图标轨）。
  static bool usesSidebar(double width) => width >= sidebarExpanded;

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

  /// 卡片圆角。
  ///
  /// 取 24 而不是 M3 默认的 12：参照应用的表面卡片（`TonalCard`）统一是
  /// 24，卡片、分组列表外框、设置侧栏行都在这个档位上。16 会让整屏读起来
  /// 「紧、工具感」，24 才是那种松弛的观感来源。
  static const double cardRadius = 24;

  /// 表面卡片圆角，与 [cardRadius] 同源。
  ///
  /// 单独留一个名字是因为它有明确出处（参照应用的 `tonalCardRadius`）：
  /// 以后若卡片与表面卡分家，改这里不影响别处。
  static const double tonalRadius = cardRadius;

  /// 海报卡圆角。参照应用的 `imgRadius` 是 12——卡片本身就是一张图，
  /// 比通用面板收紧一档才不像「相框里的照片」。
  static const double posterRadius = medium;

  /// 大块头图 / hero 面板的圆角（时间表卡、规则卡、信息卡）。
  static const double heroRadius = extraLarge;

  /// 「我的」页 bento 磁贴的不对称大圆角。
  ///
  /// 只作单边取值使用：四角全 64 会变成一个球，参照应用的做法是一两个
  /// 角给 64、其余保持 28，形成「被咬掉一口」的板块感。
  static const double bentoRadius = 64;

  /// 分组列表外圆角。
  static const double groupRadius = Md3Spacing.xl;

  /// 分组列表内圆角与行间距。
  static const double groupInnerRadius = extraSmall;
  static const double groupGap = extraSmall;

  /// 按压时卡片收窄到的圆角（形状 morph 的终点）。
  ///
  /// 与 [cardRadius] 的差值控制在 8 以内：24 → 16 是一次可读的「收紧」，
  /// 24 → 12 会让按下的瞬间像换了个控件。
  static const double pressedRadius = 16;

  static final BorderRadius card = BorderRadius.circular(cardRadius);

  /// 表面卡片的圆角。
  static final BorderRadius tonal = BorderRadius.circular(tonalRadius);

  /// 大块头图面板的圆角。
  static final BorderRadius hero = BorderRadius.circular(heroRadius);

  /// 海报卡的圆角（封面、hover 描边、按压 morph 共用一个值）。
  static final BorderRadius poster = BorderRadius.circular(posterRadius);

  static final BorderRadius chip = BorderRadius.circular(small);

  static final BorderRadius dialog = BorderRadius.circular(extraLarge);

  static final BorderRadius sheet = BorderRadius.circular(extraLarge);

  static final BorderRadius field = BorderRadius.circular(extraSmall);

  static final BorderRadius largeRadius = BorderRadius.circular(large);

  static final BorderRadius pill = BorderRadius.circular(full);

  /// 按状态插值圆角，用于按压 morph。
  ///
  /// 关闭动画时不走过场，直接给终值——`AnimatedContainer` 在零时长下
  /// 本来就瞬间到位，这里只保证首帧就是正确形状。
  static BorderRadius resolved(BuildContext context, {required bool pressed}) {
    return BorderRadius.circular(pressed ? pressedRadius : cardRadius);
  }
}

/// 表面染色与背景模糊。
///
/// 参照应用把内容区整片染成 `primaryContainer`；本项目只染「带导航的书架
/// 页」，并压到 15%，详情、设置、播放器保持 `surface`。数值集中在这里，
/// 页面不得再写透明度或 sigma。
abstract final class Md3Surface {
  /// 书架内容区混入 `primaryContainer` 的比例。
  static const double shelfTint = .15;

  /// 详情头图模糊的 sigma（参照应用为 15）。
  static const double blurSigma = 15;

  /// 模糊前把封面降采样到该比例，避免每帧重算大图。
  static const double blurDownsample = .5;

  /// 模糊背板的叠放不透明度（参照应用为 0.4）。
  static const double backdropOpacity = .4;

  /// 叠在视频画面上的提示条底色：必须自带不透明度，不随主题变化。
  static const Color videoBanner = Color(0xE6322424);
}

/// 播放器覆盖层令牌。
///
/// 播放器是「恒暗孤岛」：控件不随主题明暗漂移，一律白前景 + 黑底状态层，
/// 强调色仍取主题 primary。透明度集中在这里，播放器页面不再散写
/// `Colors.black.withValues(alpha: …)`。
abstract final class Md3PlayerOverlay {
  /// 顶 / 底 scrim 渐变的实端（另一端是 transparent）。
  static const Color scrim = Colors.black45;

  /// 图标按钮的胶囊底（顶栏按钮、紧凑「更多」）。
  static const Color pillBackground = Color(0x5C000000);

  /// 工具钮常态底。
  static const Color toolBackground = Color(0x38000000);

  /// 工具钮描边。
  static const Color toolBorder = Color(0x14FFFFFF);

  /// 工具钮前景。
  static const Color toolForeground = Color(0xEBFFFFFF);

  /// 工具钮禁用前景。
  static const Color toolDisabledForeground = Color(0x5CFFFFFF);

  /// 文字类控件的前景（弹幕开关等）。
  static const Color textForeground = Color(0xDBFFFFFF);

  /// 手势反馈条、竖排音量面板的底。
  static const Color panelBackground = Color(0xE0000000);

  /// 全屏加载遮罩。
  static const Color overlay = Color(0xC7000000);

  /// 全屏错误遮罩（更深一档）。
  static const Color overlayStrong = Color(0xE6000000);
}

/// M3 高度与表面色调。
///
/// 只用 0–3 四档：桌面应用不该出现浮在空中的重阴影，层级靠 surface
/// 容器的明度差表达，阴影只在真正的浮层上出现。
abstract final class Md3Elevation {
  static const double flat = 0;
  static const double raised = 1;
  static const double floating = 3;
  static const double overlay = 6;
}

/// 交互状态叠加层的透明度。
///
/// M3 用「状态层」而不是改变前景色来表达 hover / focus / press，
/// 这样任意表面色上都能保持对比度。
abstract final class Md3State {
  static const double hover = .08;
  static const double focus = .12;
  static const double pressed = .10;
  static const double dragged = .16;

  /// 禁用态前景透明度。
  static const double disabled = .38;

  /// 把状态层叠到表面色上。
  static Color layer(Color base, Color overlay, double opacity) =>
      Color.alphaBlend(overlay.withValues(alpha: opacity), base);
}

/// 动效令牌：Expressive 用弹簧，转场用缓动曲线。
abstract final class Md3Motion {
  static const Duration emphasized = Duration(milliseconds: 500);
  static const Duration emphasizedDecelerate = Duration(milliseconds: 400);
  static const Duration emphasizedAccelerate = Duration(milliseconds: 200);
  static const Duration standard = Duration(milliseconds: 300);
  static const Duration standardDecelerate = Duration(milliseconds: 250);
  static const Duration standardAccelerate = Duration(milliseconds: 200);

  /// 形状 morph 与状态层过渡。
  static const Duration shape = Duration(milliseconds: 250);

  /// 图片淡入淡出。
  static const Duration image = Duration(milliseconds: 120);

  /// 骨架屏脉冲半周期。
  static const Duration skeleton = Duration(milliseconds: 900);

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

  /// 读取动效时长：系统关闭动画时归零。
  static Duration of(BuildContext context, Duration duration) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;
}

/// 文字层级。
///
/// 页面不再直接写 `fontSize`：需要非默认字号时从这里取，保证同一层级
/// 在全应用一致。数值对应 M3 type scale 的桌面读法（略大于手机）。
abstract final class Md3Type {
  static const double displaySmall = 36;
  static const double headlineLarge = 32;
  static const double headlineMedium = 28;
  static const double headlineSmall = 24;
  static const double titleLarge = 22;
  static const double titleMedium = 16;
  static const double titleSmall = 14;
  static const double bodyLarge = 16;
  static const double bodyMedium = 14;
  static const double bodySmall = 12;
  static const double labelLarge = 14;
  static const double labelMedium = 12;
  static const double labelSmall = 11;
}

/// 详情页几何（参照应用 `info_page.dart`）。
///
/// 头部 = 信息区 308 + tab 条 48 + 工具栏 56；卡片固定 300 高、最大宽 950。
abstract final class Md3Detail {
  static const double infoHeight = 308;
  static const double headerHeight =
      infoHeight + kTextTabBarHeight + kToolbarHeight;
  static const double cardHeight = 300;
  static const double cardMaxWidth = 950;
  static const double coverWidth = 108;
  static const double coverHeight = 162;
  static const double backdropFeather = 64;
}

/// 首页折叠头（参照应用 `popular_page.dart`）。
abstract final class Md3HomeHeader {
  static const double height = 120;
  static const double titleExpanded = 28;
  static const double titleCollapsed = 20;
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

  /// 导航表面：rail、底栏、自绘标题栏统一用它。
  Color get shelf => surfaceContainer;

  /// 内容书架表面：`surface` 混 15% `primaryContainer`。
  ///
  /// 只给带导航的书架页用；深色下底色调到 `surfaceContainerLowest`，
  /// 否则染色与导航的明度差不足以拉出边界。
  Color get contentShelf => Color.alphaBlend(
    primaryContainer.withValues(alpha: Md3Surface.shelfTint),
    brightness == Brightness.dark ? surfaceContainerLowest : surface,
  );

  /// 网格卡片未命中任何状态时的表面。
  Color get tileSurface => surfaceContainerLow;
}
