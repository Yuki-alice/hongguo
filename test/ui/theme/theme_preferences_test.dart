import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/ui/core/app_theme.dart';

/// 主题个性化。
///
/// 四项偏好都要满足：落盘可读回、非法值有兜底、导出备份后能还原、
/// 且真的改变 `ThemeData` 而不只是存了个值。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> create([Map<String, Object> initial = const {}]) async {
    SharedPreferences.setMockInitialValues(initial);
    return LocalStore(await SharedPreferences.getInstance());
  }

  group('偏好持久化', () {
    test('默认值', () async {
      final store = await create();
      addTearDown(store.dispose);
      expect(store.themeSeed, isNull);
      expect(store.useDynamicColor, isFalse);
      expect(store.oledEnhance, isFalse);
      expect(store.useSystemFont, isTrue);
    });

    test('种子色保存后重启可读回', () async {
      final store = await create();
      addTearDown(store.dispose);
      await store.setThemeSeed('ff2e7d32');
      final restored = LocalStore(store.preferences);
      addTearDown(restored.dispose);
      expect(restored.themeSeed, 'ff2e7d32');
    });

    test('清除种子色回到品牌默认', () async {
      final store = await create();
      addTearDown(store.dispose);
      await store.setThemeSeed('ff2e7d32');
      await store.setThemeSeed(null);
      expect(store.themeSeed, isNull);
    });

    test('非法种子色被忽略而不是崩溃', () async {
      final store = await create({'themeSeed': 'not-a-color'});
      addTearDown(store.dispose);
      expect(store.themeSeed, isNull);
    });

    test('三个开关都能保存', () async {
      final store = await create();
      addTearDown(store.dispose);
      await store.setUseDynamicColor(true);
      await store.setOledEnhance(true);
      await store.setUseSystemFont(false);

      final restored = LocalStore(store.preferences);
      addTearDown(restored.dispose);
      expect(restored.useDynamicColor, isTrue);
      expect(restored.oledEnhance, isTrue);
      expect(restored.useSystemFont, isFalse);
    });

    test('导出备份包含主题设置', () async {
      final store = await create();
      addTearDown(store.dispose);
      await store.setThemeSeed('ff00658f');
      await store.setOledEnhance(true);
      final backup = await store.exportBackup();
      expect(backup, contains('ff00658f'));
      expect(backup, contains('"oledEnhance":true'));
    });

    test('旧备份没有主题字段时用默认值', () async {
      final store = await create();
      addTearDown(store.dispose);
      final backup = await store.exportBackup();
      final older = backup
          .replaceAll(RegExp(r'"themeSeed":"[^"]*",?'), '')
          .replaceAll(RegExp(r'"oledEnhance":(true|false),?'), '');
      final restored = LocalStore(store.preferences);
      addTearDown(restored.dispose);
      await restored.importBackup(older);
      expect(restored.themeSeed, isNull);
      expect(restored.oledEnhance, isFalse);
    });
  });

  group('主题构建', () {
    test('默认主题用品牌色', () {
      final theme = AppTheme.themeFor();
      expect(theme.brightness, Brightness.light);
      // 品牌色系：主色是暖色（红 > 蓝）。
      expect(
        theme.colorScheme.primary.r,
        greaterThan(theme.colorScheme.primary.b),
      );
    });

    test('自定义种子色改变主色相', () {
      final brand = AppTheme.themeFor();
      final green = AppTheme.themeFor(seedColor: AppTheme.palette[1]);
      expect(green.colorScheme.primary, isNot(brand.colorScheme.primary));
      // 绿色种子的主色，绿通道应占优。
      expect(
        green.colorScheme.primary.g,
        greaterThan(green.colorScheme.primary.r),
      );
    });

    test('OLED 只在深色模式压到纯黑', () {
      final dark = AppTheme.themeFor(brightness: Brightness.dark, oled: true);
      expect(dark.scaffoldBackgroundColor, Colors.black);
      expect(dark.colorScheme.surface, Colors.black);

      // 浅色模式忽略 oled 开关。
      final light = AppTheme.themeFor(oled: true);
      expect(light.scaffoldBackgroundColor, isNot(Colors.black));
    });

    test('OLED 保留容器层次', () {
      final dark = AppTheme.themeFor(brightness: Brightness.dark, oled: true);
      final plain = AppTheme.themeFor(brightness: Brightness.dark);
      // 表面压到黑，但容器色仍与表面不同，否则所有面板糊成一片。
      expect(
        dark.colorScheme.surfaceContainerLow,
        plain.colorScheme.surfaceContainerLow,
      );
      expect(
        dark.colorScheme.surfaceContainerLow,
        isNot(dark.colorScheme.surface),
      );
    });

    test('动态取色方案优先于种子色', () {
      final dynamicScheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF123456),
      );
      final theme = AppTheme.themeFor(
        seedColor: AppTheme.palette[2],
        dynamicScheme: dynamicScheme,
      );
      expect(theme.colorScheme.primary, dynamicScheme.primary);
    });

    test('明暗两套的语义角色都完整', () {
      for (final brightness in Brightness.values) {
        final theme = AppTheme.themeFor(
          brightness: brightness,
          oled: brightness == Brightness.dark,
        );
        final scheme = theme.colorScheme;
        // 背景与前景必须能形成对比，否则文字看不见。
        expect(scheme.surface, isNot(scheme.onSurface));
        expect(scheme.primary, isNot(scheme.onPrimary));
        expect(theme.scaffoldBackgroundColor, scheme.surface);
      }
    });
  });

  group('调色板', () {
    test('至少 8 个可选色，且不含重复', () {
      expect(AppTheme.palette.length, greaterThanOrEqualTo(8));
      expect(AppTheme.palette.toSet().length, AppTheme.palette.length);
    });

    test('第一项是品牌色', () {
      expect(AppTheme.palette.first, AppTheme.seed);
    });
  });
}
