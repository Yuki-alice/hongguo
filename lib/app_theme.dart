import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui/theme/md3_tokens.dart';

/// 应用主题。
///
/// 色板由单一品牌色经 M3 算法生成，只覆盖少量必须固定语义的角色
/// （主色定位、标签色），其余角色交给 `ColorScheme.fromSeed` 推导，
/// 保证明暗两套与对比度层级都符合规范。
abstract final class AppTheme {
  /// 品牌种子色：红果橙红。
  static const seed = Color(0xFFFF664F);

  static final light = _theme(Brightness.light);
  static final dark = _theme(Brightness.dark);

  static ThemeMode mode(String preference) => switch (preference) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static String label(String preference) => switch (preference) {
    'light' => '浅色',
    'dark' => '深色',
    _ => '跟随系统',
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

  static ThemeData _theme(Brightness brightness) {
    final scheme = _scheme(brightness);
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: scheme.surfaceTint,
        scrolledUnderElevation: 2,
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
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            letterSpacing: .1,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 40),
          padding: const EdgeInsets.symmetric(horizontal: Md3Spacing.xl),
          shape: RoundedRectangleBorder(borderRadius: Md3Shape.pill),
          side: BorderSide(color: scheme.outline),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            letterSpacing: .1,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 40),
          padding: const EdgeInsets.symmetric(horizontal: Md3Spacing.md),
          shape: RoundedRectangleBorder(borderRadius: Md3Shape.pill),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            letterSpacing: .1,
          ),
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
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        selectedColor: scheme.secondaryContainer,
        disabledColor: scheme.surfaceContainerHighest,
        labelStyle: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          letterSpacing: .1,
          color: scheme.onSurfaceVariant,
        ),
        secondaryLabelStyle: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          letterSpacing: .1,
          color: scheme.onSecondaryContainer,
        ),
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Md3Shape.small),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: Md3Spacing.md,
          vertical: Md3Spacing.sm,
        ),
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
        textStyle: TextStyle(
          fontSize: 12,
          color: scheme.onInverseSurface,
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    );
  }

  /// 品牌色定位：只固定主色与标签色，其余角色由算法推导。
  static ColorScheme _scheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      primary: dark ? const Color(0xFFFFB4A3) : const Color(0xFFB02F1C),
      onPrimary: dark ? const Color(0xFF5F1508) : Colors.white,
      primaryContainer: dark
          ? const Color(0xFF8A2413)
          : const Color(0xFFFFDAD2),
      onPrimaryContainer: dark
          ? const Color(0xFFFFDAD2)
          : const Color(0xFF3E0500),
      tertiary: dark ? const Color(0xFFF6C86B) : const Color(0xFF7A5900),
      tertiaryContainer: dark
          ? const Color(0xFF5C4300)
          : const Color(0xFFFFDF9B),
      onTertiaryContainer: dark
          ? const Color(0xFFFFDF9B)
          : const Color(0xFF261A00),
      dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
    );
  }

  static TextStyle _titleLarge(ColorScheme scheme) => TextStyle(
    fontSize: 22,
    height: 1.27,
    letterSpacing: 0,
    fontWeight: FontWeight.w600,
    color: scheme.onSurface,
  );


}
