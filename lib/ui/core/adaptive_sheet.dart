import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 应用唯一的底部弹层入口。
///
/// 基座仍是官方 [showModalBottomSheet]——拖拽关闭、scrim、路由级进出场
/// 都交给它；在此之上只做三件事：
/// - 宽度自适应：竖屏窄窗口铺满，其余场景 `min(72% 宽, 640)` 居中；
/// - 弹簧入场：内容表面从下方 200px 处带透明度弹上来（M3 Expressive 的
///   sheet 手感来自这一层，而不是路由自身的线性动画）；
/// - 单一表面：拖动条与底色由 [_SheetSurface] 自绘，避免「原生 drag
///   handle + 自绘把手」两套并存。
///
/// 新的选集、排序、筛选面板一律走这里，不要再直接调
/// `showModalBottomSheet`——那会让圆角、宽度、入场动效各页各写一套。
Future<T?> showAdaptiveSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxHeightFactor = 0.75,
  double compactLandscapeMaxHeightFactor = 0.9,
  bool useRootNavigator = false,
  RouteSettings? routeSettings,
}) {
  return showModalBottomSheet<T>(
    context: context,
    // 单一表面自持把手与背景，路由层透明，避免再叠一层圆角帽。
    backgroundColor: Colors.transparent,
    elevation: 0,
    shape: const RoundedRectangleBorder(),
    clipBehavior: Clip.none,
    constraints: _sheetConstraints(
      context,
      maxHeightFactor: maxHeightFactor,
      compactLandscapeMaxHeightFactor: compactLandscapeMaxHeightFactor,
    ),
    isScrollControlled: true,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    showDragHandle: false,
    useSafeArea: true,
    builder: (context) => _SheetSurface(child: Builder(builder: builder)),
  );
}

BoxConstraints _sheetConstraints(
  BuildContext context, {
  required double maxHeightFactor,
  required double compactLandscapeMaxHeightFactor,
}) {
  final size = MediaQuery.sizeOf(context);
  final isLandscape = size.width > size.height;
  final useFullWidth = !isLandscape && size.width < Md3WindowClass.medium;
  final maxWidth = useFullWidth
      ? size.width
      : math.min(size.width * 0.72, 640.0);
  final useExpandedLandscapeHeight = isLandscape && size.height < 600;
  final maxHeight =
      size.height *
      (useExpandedLandscapeHeight
          ? compactLandscapeMaxHeightFactor
          : maxHeightFactor);

  return BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight);
}

/// 弹层内容表面：自绘拖动条 + 顶部 28 圆角 + 弹簧入场。
class _SheetSurface extends StatefulWidget {
  const _SheetSurface({required this.child});

  final Widget child;

  @override
  State<_SheetSurface> createState() => _SheetSurfaceState();
}

class _SheetSurfaceState extends State<_SheetSurface>
    with SingleTickerProviderStateMixin {
  late final _entrance = AnimationController.unbounded(vsync: this);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _started = true;
      _entrance.value = 1;
    } else if (!_started) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || MediaQuery.disableAnimationsOf(context)) return;
        _entrance.animateWith(
          SpringSimulation(
            Md3Motion.expressiveSpring,
            0,
            1,
            0,
            snapToEnd: false,
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final background = colors.surface;
    final surface = Material(
      color: background,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(Md3Shape.extraLarge),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: theme.copyWith(scaffoldBackgroundColor: Colors.transparent),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                label: MaterialLocalizations.of(
                  context,
                ).modalBarrierDismissLabel,
                onDismiss: () => Navigator.of(context).maybePop(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: Container(
                      width: 32,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.onSurfaceVariant.withValues(alpha: .4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
              Flexible(child: widget.child),
            ],
          ),
        ),
      ),
    );

    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.topCenter,
      children: [
        // 弹簧过冲时补住底部空隙，避免露出背景色带。
        Positioned(
          left: 0,
          right: 0,
          bottom: -400,
          height: 450,
          child: ColoredBox(color: background),
        ),
        AnimatedBuilder(
          animation: _entrance,
          child: surface,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, (1 - _entrance.value) * 200),
            child: Opacity(
              opacity: _entrance.value.clamp(0.0, 1.0),
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}

/// 弹层标题头：titleLarge w700 标题 + 可选说明 + 右侧关闭按钮。
///
/// 参照应用 `MaterialBottomSheetHeader` 的语法：选集、排序这类「带名字的
/// 面板」都用它开头，让所有弹层有同一张脸。
class AppSheetHeader extends StatelessWidget {
  const AppSheetHeader({
    super.key,
    required this.title,
    this.description,
    this.onClose,
  });

  final String title;
  final String? description;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Md3Spacing.xl,
        Md3Spacing.xs,
        Md3Spacing.md,
        Md3Spacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: Md3Type.titleLarge,
                    fontWeight: FontWeight.w700,
                    color: colors.onSurface,
                  ),
                ),
                if (description != null && description!.isNotEmpty) ...[
                  const SizedBox(height: Md3Spacing.xs),
                  Text(
                    description!,
                    style: TextStyle(
                      fontSize: Md3Type.bodySmall,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: onClose ?? () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}
