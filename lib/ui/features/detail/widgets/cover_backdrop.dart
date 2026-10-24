import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 详情页的沉浸头。
///
/// 用封面做一层降采样模糊背景，让页面从「白底 + 一块海报」变成有氛围的
/// 详情页。参数不是随手写的：
///
/// - 先按 [downsample] 缩小再模糊，模糊代价降为 1/4，且不会出现大半径
///   模糊在高分屏上的条带；
/// - [blurSigma] 按缩小比例同步缩放，否则画面会比预期更模糊；
/// - [edgeBleed] 多画一圈，遮住模糊在边缘处的衰减；
/// - 底部 [bottomFeather] 渐变到页面底色，避免出现一条硬边。
///
/// 整层 `IgnorePointer`，不拦截滚动与点击。
class CoverBackdrop extends StatelessWidget {
  const CoverBackdrop({
    super.key,
    required this.drama,
    required this.repository,
    this.height = 320,
    this.downsample = Md3Surface.blurDownsample,
    this.blurSigma = Md3Surface.blurSigma,
    this.opacity = Md3Surface.backdropOpacity,
    this.edgeBleed = 32,
    this.bottomFeather = 48,
  });

  final Drama drama;
  final AppRepository repository;
  final double height;
  final double downsample;
  final double blurSigma;
  final double opacity;
  final double edgeBleed;
  final double bottomFeather;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (drama.cover.isEmpty || DramaCover.imagesDisabled) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: ClipRect(
                child: Transform.scale(
                  // 放大回原尺寸，抵消降采样。
                  scale: 1 / downsample,
                  alignment: Alignment.topCenter,
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(
                      sigmaX: blurSigma * downsample,
                      sigmaY: blurSigma * downsample,
                      tileMode: TileMode.decal,
                    ),
                    child: ColorFiltered(
                      colorFilter: ColorFilter.mode(
                        Colors.white.withValues(alpha: opacity),
                        BlendMode.modulate,
                      ),
                      child: SizedBox(
                        height: height * downsample + edgeBleed,
                        child: CachedCoverImage(
                          drama: drama,
                          repository: repository,
                          placeholder: const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 底部羽化到页面底色。
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: bottomFeather,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      colors.surface.withValues(alpha: 0),
                      colors.surface.withValues(alpha: .55),
                      colors.surface,
                    ],
                    stops: const [0, .72, 1],
                  ),
                ),
              ),
            ),
            // 顶部同样淡出，避免在 AppBar 下方出现硬边。
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: bottomFeather,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      colors.surface.withValues(alpha: .8),
                      colors.surface.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 详情页顶部的大标题。
///
/// 桌面端标题字号比移动端大一档，并与封面并列；滚动后由 `SliverAppBar`
/// 接管成小标题。
class DetailHeadline extends StatelessWidget {
  const DetailHeadline({
    super.key,
    required this.title,
    this.subtitle,
    this.width = 0,
  });

  final String title;
  final String? subtitle;
  final double width;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final large = width >= Md3WindowClass.expanded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: large ? Md3Type.headlineMedium : Md3Type.headlineSmall,
            height: 1.25,
            fontWeight: FontWeight.w700,
            color: colors.onSurface,
            letterSpacing: -.2,
          ),
        ),
        if (subtitle != null && subtitle!.isNotEmpty) ...[
          const SizedBox(height: Md3Spacing.sm),
          Text(
            subtitle!,
            style: TextStyle(
              fontSize: Md3Type.bodyMedium,
              color: colors.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ],
    );
  }
}
