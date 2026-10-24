import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 详情页的三种自适应形态。
///
/// 断点与尺寸参照 animeko 的 `SubjectDetailsLayoutParams`（其数值来自
/// Figma 定稿），按 Flutter 的窗口宽度重新表达：
///
/// | 宽度 | 形态 | 侧栏 | 列距 | 页面留白 |
/// | --- | --- | --- | --- | --- |
/// | < 600 | 单列 | — | — | 16 |
/// | 600–1000 | 窄双栏 | 280 | 24 | 24 |
/// | 1000–1600 | 双栏 | 340 | 48 | 40 |
/// | ≥ 1600 | 三栏（加右栏） | 340 | 48 | 48 |
///
/// 窄双栏是独立的档位而不是插值：600dp 下 340 的侧栏 + 48 的列距只给
/// 中栏剩不到 200，必须收缩侧栏与留白，否则中栏内容挤成一列字。
@immutable
class DetailLayout {
  const DetailLayout({
    required this.kind,
    required this.sidebarWidth,
    required this.railWidth,
    required this.columnSpacing,
    required this.pagePadding,
    required this.sectionSpacing,
    this.sidebarItemSpacing = 20,
  });

  final DetailPaneKind kind;

  /// 左侧信息栏宽度（单列为 0）。
  final double sidebarWidth;

  /// 右侧栏宽度（仅三栏）。
  final double railWidth;

  /// 栏与栏之间的水平间距。
  final double columnSpacing;

  /// 页面左右留白。
  final double pagePadding;

  /// 中栏各区块之间的竖向间距。
  final double sectionSpacing;

  /// 侧栏内部各块之间的竖向间距。
  final double sidebarItemSpacing;

  bool get isMultiColumn => kind != DetailPaneKind.compact;
  bool get showRail => kind == DetailPaneKind.expanded;

  static const compact = DetailLayout(
    kind: DetailPaneKind.compact,
    sidebarWidth: 0,
    railWidth: 0,
    columnSpacing: 0,
    pagePadding: 16,
    sectionSpacing: 20,
  );

  static const mediumNarrow = DetailLayout(
    kind: DetailPaneKind.medium,
    sidebarWidth: 280,
    railWidth: 0,
    columnSpacing: 24,
    pagePadding: 24,
    sectionSpacing: 24,
  );

  static const medium = DetailLayout(
    kind: DetailPaneKind.medium,
    sidebarWidth: 340,
    railWidth: 0,
    columnSpacing: 48,
    pagePadding: 40,
    sectionSpacing: 28,
  );

  static const expanded = DetailLayout(
    kind: DetailPaneKind.expanded,
    sidebarWidth: 340,
    railWidth: 372,
    columnSpacing: 48,
    pagePadding: 48,
    sectionSpacing: 28,
  );

  /// 双栏断点（M3 medium）。
  static const double mediumWidth = 600;

  /// 双栏加宽断点：再窄就用 [mediumNarrow]。
  static const double wideWidth = 1000;

  /// 三栏断点。
  static const double expandedWidth = 1600;

  /// 按**页面实际可用宽度**选形态。
  ///
  /// 不能用窗口宽度：详情页会被内嵌到播放页的侧栏、下载选集弹层里，
  /// 那些位置远窄于窗口。
  static DetailLayout of(double width) => switch (width) {
    >= expandedWidth => expanded,
    >= wideWidth => medium,
    >= mediumWidth => mediumNarrow,
    _ => compact,
  };
}

enum DetailPaneKind { compact, medium, expanded }
