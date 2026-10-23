import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 布局契约测试。
///
/// 这些用例锁定的是**结构规则**而不是像素：任何页面都不允许在宽窗口里
/// 把手机布局横向拉宽。像素级回归交给 `scripts/capture_screens.py` 的
/// 人工比对——golden 图在中文字体与不同 CI runner 上会持续误报。
void main() {
  group('窗口等级', () {
    test('按 M3 断点分级', () {
      expect(Md3WindowClass.of(390), Md3WindowSize.compact);
      expect(Md3WindowClass.of(599), Md3WindowSize.compact);
      expect(Md3WindowClass.of(600), Md3WindowSize.medium);
      expect(Md3WindowClass.of(839), Md3WindowSize.medium);
      expect(Md3WindowClass.of(840), Md3WindowSize.expanded);
      expect(Md3WindowClass.of(1199), Md3WindowSize.expanded);
      expect(Md3WindowClass.of(1200), Md3WindowSize.large);
      expect(Md3WindowClass.of(1599), Md3WindowSize.large);
      expect(Md3WindowClass.of(1600), Md3WindowSize.extraLarge);
    });

    test('导航形态只在 600 处切换一次', () {
      // 底部导航 → 侧栏
      expect(Md3WindowClass.usesRail(599), isFalse);
      expect(Md3WindowClass.usesRail(600), isTrue);
      // 侧栏内部：600–900 收起为图标轨，≥900 常驻展开
      expect(Md3WindowClass.usesSidebar(899), isFalse);
      expect(Md3WindowClass.usesSidebar(900), isTrue);
    });

    test('最窄窗口宽度能容纳底部导航', () {
      expect(Md3WindowClass.minimumWindow, greaterThanOrEqualTo(360));
      expect(Md3WindowClass.minimumWindow, lessThan(Md3WindowClass.medium));
    });

    test('双栏布局在 840 起可用', () {
      expect(Md3WindowClass.usesTwoPane(839), isFalse);
      expect(Md3WindowClass.usesTwoPane(840), isTrue);
    });
  });

  group('页面留白', () {
    test('随窗口等级递增，且不会回退', () {
      const widths = [320.0, 390.0, 600.0, 840.0, 1000.0, 1200.0, 1600.0, 2560.0];
      var previous = 0.0;
      for (final width in widths) {
        final inset = Md3Spacing.pageInset(width);
        expect(
          inset,
          greaterThanOrEqualTo(previous),
          reason: '$width 宽下的留白不应小于更窄的窗口',
        );
        previous = inset;
      }
      // 手机与桌面必须不同，否则桌面看起来就是拉宽的手机。
      expect(
        Md3Spacing.pageInset(2560),
        greaterThan(Md3Spacing.pageInset(390)),
      );
    });

    test('大窗口留白仍在合理区间', () {
      for (final width in [1200.0, 1600.0, 2560.0, 3840.0]) {
        expect(Md3Spacing.pageInset(width), inInclusiveRange(16, 48));
      }
    });

    test('网格行距不大于列距', () {
      // 卡片自带文字区，行距再宽一级就会读成「一行海报一行空白」。
      // 改造前是 18 / 12，正是整屏网格显得松散的原因。
      expect(Md3Grid.rowSpacing, lessThanOrEqualTo(Md3Grid.spacing));
    });
  });

  group('海报网格（照抄 Kazumi）', () {
    test('列数按 600 / 840 两个断点给 3 / 5 / 6', () {
      // Kazumi 不给「目标卡宽」而是按断点给列数，卡片尺寸随窗口变大。
      expect(Md3Grid.columns(358), 3);
      expect(Md3Grid.columns(600), 3);
      expect(Md3Grid.columns(601), 5);
      expect(Md3Grid.columns(840), 5);
      expect(Md3Grid.columns(841), 6);
      expect(Md3Grid.columns(4000), 6);
    });

    test('间距与海报比例是 Kazumi 的那组值', () {
      expect(Md3Grid.spacing, 8); // StyleString.cardSpace
      expect(Md3Grid.rowSpacing, 6); // cardSpace - 2：行比列更紧
      expect(Md3Grid.textReserve, 32);
      // 10:16 而不是 2:3——Kazumi 的海报明显更「长」。
      expect(Md3Grid.posterRatio, closeTo(.65, .001));
    });

    test('内容宽度上限把海报尺寸兜住', () {
      // Kazumi 用窗口宽度算列数，2560 宽下单张海报接近 400px。这里列数
      // 同样是 6，但内容宽被 wideMaxWidth 夹住，于是最大也只到 233 左右。
      final columns = Md3Grid.columns(Md3Spacing.wideMaxWidth);
      final tile = Md3Grid.tileWidth(Md3Spacing.wideMaxWidth, columns);
      expect(columns, 6);
      expect(tile, lessThanOrEqualTo(240));
    });

    test('遥控可以收紧列数', () {
      // 焦点左右移动的路径要短，电视用 min / max 把列数压下来。
      expect(Md3Grid.columns(1920, min: 1, max: 4), 4);
    });
  });

  group('内容宽度上限', () {
    test('媒体页上限宽于文本页上限', () {
      // 网格可以铺开，但长文本行不能无限长。
      expect(
        Md3Spacing.wideMaxWidth,
        greaterThan(Md3Spacing.contentMaxWidth),
      );
      // 1040 是 M3 推荐的可读行宽上限附近，1440 是四列海报的合理上限。
      expect(Md3Spacing.contentMaxWidth, inInclusiveRange(900, 1200));
      expect(Md3Spacing.wideMaxWidth, inInclusiveRange(1200, 1600));
    });

    test('内容区在 2560 宽下仍受约束', () {
      const window = 2560.0;
      final inset = Md3Spacing.pageInset(window);
      final available = window - inset * 2;
      // 内容宽度取 min(可用宽度, 上限)：两者之差就是两侧留白。
      final textContent = available.clamp(0.0, Md3Spacing.contentMaxWidth);
      final mediaContent = available.clamp(0.0, Md3Spacing.wideMaxWidth);
      expect(textContent, Md3Spacing.contentMaxWidth);
      expect(mediaContent, Md3Spacing.wideMaxWidth);
      // 文本内容两侧至少各留 560，避免 2560 下出现一整行文字。
      expect((window - textContent) / 2, greaterThan(500));
    });
  });

  group('形状与状态', () {
    test('卡片圆角小于弹层圆角', () {
      expect(Md3Shape.cardRadius, lessThan(Md3Shape.extraLarge));
      expect(Md3Shape.cardRadius, greaterThanOrEqualTo(Md3Shape.medium));
    });

    test('分组列表外圆角大于内圆角', () {
      expect(Md3Shape.groupRadius, greaterThan(Md3Shape.groupInnerRadius));
      expect(Md3Shape.groupGap, greaterThan(0));
    });

    test('按压 morph 收窄圆角', () {
      expect(Md3Shape.pressedRadius, lessThan(Md3Shape.cardRadius));
    });

    test('状态层透明度在可辨识但不喧宾夺主的区间', () {
      for (final value in [
        Md3State.hover,
        Md3State.focus,
        Md3State.pressed,
        Md3State.dragged,
      ]) {
        expect(value, inExclusiveRange(0.0, 0.3));
      }
      // focus 必须比 hover 明显，否则键盘用户看不出焦点。
      expect(Md3State.focus, greaterThan(Md3State.hover));
    });

    test('状态层不改变表面的不透明度', () {
      const base = Color(0xFF202124);
      final hovered = Md3State.layer(base, Colors.white, Md3State.hover);
      expect(hovered.a, base.a);
      expect(hovered, isNot(base));
    });
  });

  group('动效', () {
    test('骨架屏周期足够长，不会闪烁', () {
      expect(
        Md3Motion.skeleton.inMilliseconds,
        greaterThanOrEqualTo(600),
      );
    });

    test('图片淡入短于形状 morph', () {
      expect(
        Md3Motion.image.inMilliseconds,
        lessThan(Md3Motion.shape.inMilliseconds),
      );
    });

    testWidgets('系统关闭动画时时长归零', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(Md3Motion.of(captured, Md3Motion.standard), Duration.zero);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(),
          child: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(Md3Motion.of(captured, Md3Motion.standard), Md3Motion.standard);
    });
  });

  group('字体层级', () {
    test('卡片标题在宽窗口放大一档', () {
      expect(Md3Type.cardTitle(390), Md3Type.titleSmall);
      expect(Md3Type.cardTitle(840), greaterThan(Md3Type.titleSmall));
      expect(Md3Type.cardTitle(2560), Md3Type.cardTitle(840));
    });

    test('同一字体族内字号严格递减', () {
      // 跨族可以相等（M3 里 titleSmall 与 bodyMedium 都是 14），
      // 族内必须递减，否则层级读不出来。
      final families = <String, List<double>>{
        'headline': [
          Md3Type.headlineLarge,
          Md3Type.headlineMedium,
          Md3Type.headlineSmall,
        ],
        'title': [
          Md3Type.titleLarge,
          Md3Type.titleMedium,
          Md3Type.titleSmall,
        ],
        'body': [Md3Type.bodyLarge, Md3Type.bodyMedium, Md3Type.bodySmall],
        'label': [
          Md3Type.labelLarge,
          Md3Type.labelMedium,
          Md3Type.labelSmall,
        ],
      };
      families.forEach((name, scale) {
        for (var i = 1; i < scale.length; i++) {
          expect(
            scale[i],
            lessThan(scale[i - 1]),
            reason: '$name 第 $i 档字号应小于前一档',
          );
        }
      });
    });

    test('正文字号不低于 12，保证中文可读', () {
      expect(Md3Type.bodySmall, greaterThanOrEqualTo(12));
      expect(Md3Type.labelSmall, greaterThanOrEqualTo(11));
    });
  });
}
