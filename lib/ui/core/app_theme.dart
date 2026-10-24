import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 应用主题。
///
/// 色板由单一品牌色经 M3 算法生成，只覆盖少量必须固定语义的角色
/// （主色定位、标签色），其余角色交给 `ColorScheme.fromSeed` 推导，
/// 保证明暗两套与对比度层级都符合规范。
abstract final class AppTheme {
  /// 品牌种子色：「星」的星野靛蓝。
  ///
  /// 选靛蓝而不是暖色是刻意的权衡：这个应用的主视觉是海报网格，暖色主色
  /// 会与封面色竞争，让整屏显得燥。靛蓝在深色海报之间是退让色，同时仍能
  /// 承担导航指示器、进度条这些需要被看见的角色。星辉金作为 tertiary 继续
  /// 承担 VIP 与高光。
  static const seed = Color(0xFF2F4F86);

  /// 可选种子色。第一项是品牌色，其余是常见偏好。
  ///
  /// 只给固定几个而不是任意取色：任意色会让「主色定位」与「标签色」
  /// 这两处手工覆盖失去意义，也容易出现对比度不足的搭配。
  static const palette = <Color>[
    seed,
    Color(0xFF2E7D32),
    Color(0xFF00658F),
    Color(0xFF4B5CC4),
    Color(0xFF7B4E9E),
    Color(0xFFB3367A),
    Color(0xFFB07A00),
    Color(0xFF4E6B7A),
    Color(0xFF6B6B6B),
  ];

  /// 默认主题（品牌色、无 OLED）。
  static final light = themeFor();
  static final dark = themeFor(brightness: Brightness.dark);

  /// 内置中文字体族名，与 `pubspec.yaml` 的 `fonts.family` 同名。
  static const fontFamily = 'MiSans';

  /// 按用户偏好构建主题。
  ///
  /// [seedColor] 为 null 时用品牌色；[oled] 只在深色模式生效，
  /// 把表面与背景压到纯黑，OLED 屏更省电、对比度更高。
  /// [useSystemFont] 为真时不指定字体族，交给平台默认中文字体。
  static ThemeData themeFor({
    Brightness brightness = Brightness.light,
    Color? seedColor,
    bool oled = false,
    ColorScheme? dynamicScheme,
    bool useSystemFont = false,
  }) {
    final base = _theme(
      brightness,
      seedColor: seedColor,
      dynamicScheme: dynamicScheme,
      fontFamily: useSystemFont ? null : fontFamily,
    );
    if (!oled || brightness != Brightness.dark) return base;
    return _oled(base);
  }

  /// 把深色主题压到纯黑。
  ///
  /// 只改背景、表面与几处对比色；容器色保留，否则层次全丢、所有面板
  /// 糊成一片黑。
  static ThemeData _oled(ThemeData theme) {
    final scheme = theme.colorScheme.copyWith(
      surface: Colors.black,
      onSurface: Colors.white,
      onPrimary: Colors.black,
      onSecondary: Colors.black,
      surfaceDim: Colors.black,
    );
    return theme.copyWith(
      scaffoldBackgroundColor: Colors.black,
      canvasColor: Colors.black,
      colorScheme: scheme,
      appBarTheme: theme.appBarTheme.copyWith(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
    );
  }

  static ThemeMode mode(String preference) => switch (preference) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static String label(String preference, AppLocalizations l10n) =>
      switch (preference) {
        'light' => l10n.themeLight,
        'dark' => l10n.themeDark,
        _ => l10n.themeSystem,
      };

  static SystemUiOverlayStyle systemBars(Brightness brightness) {
    final icons = brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      statusBarBrightness: brightness,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
    );
  }

  static ThemeData _theme(
    Brightness brightness, {
    Color? seedColor,
    ColorScheme? dynamicScheme,
    String? fontFamily,
  }) {
    final scheme =
        dynamicScheme?.copyWith(brightness: brightness) ??
        _scheme(brightness, seedColor: seedColor);
    return ThemeData(
      useMaterial3: true,
      fontFamily: fontFamily,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      // 桌面滚动条：常显、细、圆角，hover 时加深。Flutter 默认滚动条只在
      // 滚动时闪一下，鼠标用户很难发现内容还能继续滚。
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.dragged)
              ? scheme.onSurface.withValues(alpha: .55)
              : scheme.onSurface.withValues(alpha: .3),
        ),
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(4),
        crossAxisMargin: 2,
        mainAxisMargin: 2,
        interactive: true,
      ),
      appBarTheme: AppBarTheme(
        // 透明：内容区的底色由外壳书架提供，AppBar 再画一层会在圆角
        // 处露出直角色带。
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: _titleLarge(scheme),
        systemOverlayStyle: systemBars(brightness),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        surfaceTintColor: scheme.surfaceTint,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: Md3Shape.card),
        clipBehavior: Clip.antiAlias,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: scheme.surfaceTint,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
        elevation: 0,
        height: 80,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected)
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            height: 1.33,
            letterSpacing: .4,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
        useIndicator: true,
        selectedIconTheme: IconThemeData(
          size: 24,
          color: scheme.onSecondaryContainer,
        ),
        unselectedIconTheme: IconThemeData(
          size: 24,
          color: scheme.onSurfaceVariant,
        ),
        selectedLabelTextStyle: TextStyle(
          fontSize: 12,
          letterSpacing: .4,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontSize: 12,
          letterSpacing: .4,
          fontWeight: FontWeight.w500,
          color: scheme.onSurfaceVariant,
        ),
        labelType: NavigationRailLabelType.all,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 40),
          padding: const EdgeInsets.symmetric(horizontal: Md3Spacing.xl),
          shape: RoundedRectangleBorder(borderRadius: Md3Shape.pill),
          textStyle: _labelStyle(scheme),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 40),
          padding: const EdgeInsets.symmetric(horizontal: Md3Spacing.xl),
          shape: RoundedRectangleBorder(borderRadius: Md3Shape.pill),
          side: BorderSide(color: scheme.outline),
          textStyle: _labelStyle(scheme),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 40),
          padding: const EdgeInsets.symmetric(horizontal: Md3Spacing.md),
          shape: RoundedRectangleBorder(borderRadius: Md3Shape.pill),
          textStyle: _labelStyle(scheme),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: Md3Shape.pill),
          ),
          side: WidgetStatePropertyAll(BorderSide(color: scheme.outline)),
        ),
      ),
      // 胶囊筛选条：未选中是「无填充 + 细描边」，选中才填色。
      //
      // 全部胶囊都带填充时，一行 8–10 个胶囊会连成一块实心色带，
      // 视觉重量压过下面的海报。Kazumi 的分类条是纯文本 + 下拉，
      // 这里取其中间的表达：描边胶囊、选中填色。
      chipTheme: ChipThemeData(
        backgroundColor: Colors.transparent,
        selectedColor: scheme.secondaryContainer,
        disabledColor: scheme.surfaceContainerHighest,
        // 从 textTheme 派生而不是写死 TextStyle：否则会丢掉字体族与
        // 中文回退，测试环境里分类名会渲染成方块。
        labelStyle: _labelStyle(
          scheme,
        ).copyWith(color: scheme.onSurfaceVariant),
        secondaryLabelStyle: _labelStyle(scheme).copyWith(
          color: scheme.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: Md3Shape.pill),
        // 比默认更紧凑：密一些才能在 800px 宽里一屏看到更多分类。
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
        showCheckmark: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Md3Spacing.lg,
          vertical: Md3Spacing.md,
        ),
        border: OutlineInputBorder(
          borderRadius: Md3Shape.field,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: Md3Shape.field,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: Md3Shape.field,
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
        actionTextColor: scheme.inversePrimary,
        shape: RoundedRectangleBorder(borderRadius: Md3Shape.chip),
        insetPadding: const EdgeInsets.all(Md3Spacing.lg),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: scheme.surfaceTint,
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: Md3Shape.dialog),
        titleTextStyle: _titleLarge(scheme),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: scheme.surfaceTint,
        modalBackgroundColor: scheme.surfaceContainerLow,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(Md3Shape.extraLarge),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Md3Spacing.lg,
          vertical: Md3Spacing.xs,
        ),
        shape: RoundedRectangleBorder(borderRadius: Md3Shape.chip),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: scheme.surfaceContainerHighest,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.surfaceContainerHighest,
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: .12),
        trackHeight: 4,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(Md3Shape.extraSmall),
        ),
        textStyle: TextStyle(fontSize: 12, color: scheme.onInverseSurface),
      ),
      // 弹层：Expressive 大圆角 + 状态层，不做重阴影。
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        surfaceTintColor: scheme.surfaceTint,
        elevation: Md3Elevation.floating,
        shape: RoundedRectangleBorder(borderRadius: Md3Shape.dialog),
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: Md3Type.bodyMedium, color: scheme.onSurface),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
          surfaceTintColor: WidgetStatePropertyAll(scheme.surfaceTint),
          elevation: const WidgetStatePropertyAll(Md3Elevation.floating),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: Md3Shape.dialog),
          ),
        ),
      ),
      // 转场按 V1 的平台分派表：移动端沿用 Cupertino 的整页横移，
      // 桌面端用 FadeUpwards（设置子页单独走 FadeForwards，见路由）。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    );
  }

  /// 品牌色定位：只固定主色与标签色，其余角色由算法推导。
  static ColorScheme _scheme(Brightness brightness, {Color? seedColor}) {
    final dark = brightness == Brightness.dark;
    final effective = seedColor ?? seed;
    // 非品牌色时不再手工覆盖 primary 等角色：那几组色值是围绕品牌靛蓝调的，
    // 套到绿/橙上会出现色相不一致。
    if (seedColor != null && seedColor != seed) {
      return ColorScheme.fromSeed(
        seedColor: effective,
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
      );
    }
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      primary: dark ? const Color(0xFFAEC6FF) : const Color(0xFF2B4B80),
      onPrimary: dark ? const Color(0xFF16325B) : Colors.white,
      primaryContainer: dark
          ? const Color(0xFF17375F)
          : const Color(0xFFD6E3FF),
      onPrimaryContainer: dark
          ? const Color(0xFFD6E3FF)
          : const Color(0xFF0B1D33),
      // 星辉金：VIP 角标与高光。明色下要压暗才够对比，暗色下才提亮。
      tertiary: dark ? const Color(0xFFE8C46A) : const Color(0xFF8A6A00),
      tertiaryContainer: dark
          ? const Color(0xFF5C4500)
          : const Color(0xFFFFE08A),
      onTertiaryContainer: dark
          ? const Color(0xFFFFE08A)
          : const Color(0xFF2A1D00),
      dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
    );
  }

  static TextStyle _titleLarge(ColorScheme scheme) => TextStyle(
    fontSize: Md3Type.titleLarge,
    height: 1.27,
    letterSpacing: 0,
    fontWeight: FontWeight.w600,
    color: scheme.onSurface,
  );

  /// 按钮与标签文字。
  ///
  /// 只定字号与字重，不设颜色——前景色由各按钮自己的 `foregroundColor`
  /// 决定（filled / outlined / text 三态不同）。这样也能继承字体族与
  /// 中文回退，不会在测试环境里渲染成方块。
  static TextStyle _labelStyle(ColorScheme scheme) => TextStyle(
    fontSize: Md3Type.labelLarge,
    fontWeight: FontWeight.w500,
    letterSpacing: .1,
  );
}
