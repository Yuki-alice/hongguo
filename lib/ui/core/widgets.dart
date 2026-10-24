import 'dart:io';

import 'package:flutter/material.dart';

import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';
import 'package:hoshi/ui/core/empty_state.dart';

Future<void> saveUserChange(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).detailSaveFailed)),
      );
    }
  }
}

class RefreshAction extends StatefulWidget {
  const RefreshAction({
    super.key,
    required this.loading,
    required this.tooltip,
    required this.onPressed,
  });
  final bool loading;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  State<RefreshAction> createState() => _RefreshActionState();
}

class _RefreshActionState extends State<RefreshAction>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation;

  @override
  void initState() {
    super.initState();
    _rotation = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    if (widget.loading) _rotation.repeat();
  }

  @override
  void didUpdateWidget(covariant RefreshAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.loading == oldWidget.loading) return;
    if (widget.loading) {
      _rotation.repeat();
    } else {
      _rotation.reset();
    }
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Semantics(
      liveRegion: true,
      value: widget.loading ? l10n.updating : null,
      child: IconButton(
        tooltip: widget.loading ? l10n.updating : widget.tooltip,
        onPressed: widget.loading ? null : widget.onPressed,
        disabledColor: widget.loading
            ? Theme.of(context).colorScheme.primary
            : null,
        icon: RotationTransition(
          turns: _rotation,
          child: const Icon(Icons.refresh_rounded),
        ),
      ),
    );
  }
}

class DramaCover extends StatelessWidget {
  const DramaCover({
    super.key,
    required this.drama,
    required this.repository,
    this.radius = Md3Shape.posterRadius,
    this.heroTag,
  });
  final Drama drama;
  final AppRepository repository;

  /// 封面圆角。默认 [Md3Shape.posterRadius]，与卡片外层（`InkWell`、hover
  /// 描边、按压 morph）同值——两者不同值时桌面悬停会看到一圈错位。
  final double radius;

  /// Hero 标签。给出时封面参与转场。
  ///
  /// 只在**同一个 Navigator** 内的两个页面之间生效：详情页挂在根
  /// Navigator，卡片挂在分支 Navigator，go_router 给每个 Navigator
  /// 单独装了 `HeroControllerScope`，跨层转场不会触发。因此这里用于
  /// 详情 → 详情（切季）与榜单 → 详情这类同层跳转。
  final Object? heroTag;

  static const imagesDisabled = bool.fromEnvironment('DISABLE_REMOTE_IMAGES');

  /// 转场途中保持主题与图片不闪白。
  ///
  /// 默认 shuttle 会把 `Image` 直接放进 overlay，丢掉 `InheritedTheme`，
  /// 深色模式下会出现白底闪一下。
  static Widget heroFlightShuttleBuilder(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection direction,
    BuildContext fromContext,
    BuildContext toContext,
  ) {
    final hero = direction == HeroFlightDirection.push
        ? fromContext.widget as Hero
        : toContext.widget as Hero;
    final source = direction == HeroFlightDirection.push
        ? fromContext
        : toContext;
    return InheritedTheme.captureAll(
      source,
      Material(type: MaterialType.transparency, child: hero.child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 封面就是一张干净的图：不叠压暗渐变、不把集数与 VIP 烧进画面里。
    // 这些信息属于卡片文字区（见 [DramaTile]），叠在封面上会让整屏网格
    // 变成一片「底部发黑的海报」，也把图片本身的可读性打掉。
    //
    // 占位是一块中性灰洗色而不是图标：图标会在每张海报未到位时闪出
    // 一片同形图案，比纯色更吵。用 `onSurface` 叠层而不是容器色——
    // 内容书架本身带品牌色调，容器色压在上面几乎看不出来，
    // 海报没加载出来时整张卡片会「只剩文字」。
    final placeholder = ColoredBox(
      color: Md3State.layer(colors.surface, colors.onSurface, .10),
    );
    // 占位垫在底下而不是只用在加载中：取图失败时上面只剩一个重试按钮，
    // 没有这一层的话失败的海报会「透明消失」，整张卡片只剩文字。
    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: imagesDisabled || drama.id.isEmpty
          ? placeholder
          : Stack(
              fit: StackFit.expand,
              children: [
                placeholder,
                CachedCoverImage(
                  key: ValueKey('${drama.id}\u0000${drama.cover}'),
                  drama: drama,
                  repository: repository,
                  placeholder: const SizedBox.shrink(),
                ),
              ],
            ),
    );
    final tag = heroTag;
    if (tag == null) return cover;
    return Hero(
      tag: tag,
      transitionOnUserGestures: true,
      flightShuttleBuilder: heroFlightShuttleBuilder,
      child: cover,
    );
  }
}

class CachedCoverImage extends StatefulWidget {
  const CachedCoverImage({
    super.key,
    required this.drama,
    required this.repository,
    required this.placeholder,
  });
  final Drama drama;
  final AppRepository repository;
  final Widget placeholder;
  @override
  State<CachedCoverImage> createState() => _CachedCoverImageState();
}

class _CachedCoverImageState extends State<CachedCoverImage> {
  late Future<String> _file;
  int _coverRevision = 0;
  bool _coverFailed = false;
  bool _retryOnFailure = false;
  bool _retryQueued = false;
  String? _failedPath;

  @override
  void initState() {
    super.initState();
    _coverRevision = widget.repository.catalogUpdates.coverRevision(
      widget.drama.id,
    );
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    // `.ignore()` 只是告诉测试框架「这个 Future 的错误有人处理」，
    // FutureBuilder 拿到的仍是**原始** Future：错误照常进入 hasError 分支，
    // 失败态的重试按钮才会出现。之前的 catchError 会把错误吞成空串，
    // 让 FutureBuilder 走 hasData 分支去渲染一张空路径的图片。
    final future = widget.repository.cover(widget.drama);
    future.ignore();
    _file = future;
  }

  @override
  void didUpdateWidget(covariant CachedCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository.catalogUpdates.removeListener(_metadataChanged);
      widget.repository.catalogUpdates.addListener(_metadataChanged);
    }
    if (oldWidget.repository != widget.repository ||
        oldWidget.drama.id != widget.drama.id ||
        oldWidget.drama.cover != widget.drama.cover ||
        oldWidget.drama.source != widget.drama.source) {
      _coverFailed = _retryOnFailure = false;
      _failedPath = null;
      _coverRevision = widget.repository.catalogUpdates.coverRevision(
        widget.drama.id,
      );
      _file = widget.repository.cover(widget.drama);
    }
  }

  void _metadataChanged() {
    final revision = widget.repository.catalogUpdates.coverRevision(
      widget.drama.id,
    );
    if (revision == _coverRevision) return;
    _coverRevision = revision;
    _retryOnFailure = true;
    if (_coverFailed) _queueRetry();
  }

  void _queueRetry() {
    if (_retryQueued || !_retryOnFailure) return;
    _retryQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _retryQueued = false;
      if (!mounted || !_retryOnFailure) return;
      _retryOnFailure = false;
      _retry(_failedPath);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    super.dispose();
  }

  Future<void> _retry(String? path) async {
    if (path != null) {
      await ResizeImage.resizeIfNeeded(
        440,
        null,
        FileImage(File(path)),
      ).evict();
    }
    if (mounted) {
      // 立刻给 Future 挂上错误监听：`FutureBuilder` 要到下一帧才订阅它，
      // 而「该剧没有海报」这类校验错误是异步抛出的；若无人同步监听，
      // 会被测试框架当成未捕获异常直接判失败。
      Future<String> file;
      try {
        file = widget.repository.cover(
          widget.repository.catalogUpdates.current(widget.drama),
          force: true,
        );
      } catch (error) {
        file = Future<String>.error(error);
      }
      // 与 initState 同理：旁路监听用 `ignore()`，不吞错误。
      file.ignore();
      setState(() {
        _coverFailed = _retryOnFailure = false;
        _failedPath = null;
        _file = file;
      });
    }
  }

  Widget _failed(String? path) {
    _coverFailed = true;
    _failedPath = path;
    if (_retryOnFailure) _queueRetry();
    return Center(
      child: IconButton(
        tooltip: AppLocalizations.of(context).retryPoster,
        onPressed: () => _retry(path),
        icon: Icon(
          Icons.refresh_rounded,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _file,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return widget.placeholder;
      }
      if (snapshot.hasError || !snapshot.hasData) {
        return _failed(null);
      }
      return Image.file(
        File(snapshot.data!),
        fit: BoxFit.cover,
        cacheWidth: 440,
        excludeFromSemantics: true,
        // 解码完成后的 120ms 淡入：占位块先垫底，图片再浮上来。
        // 系统开启「减少动态」时直接硬切。
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded) return child;
          return AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: Md3Motion.of(context, Md3Motion.image),
            curve: Curves.easeOut,
            child: child,
          );
        },
        errorBuilder: (_, error, stack) => _failed(snapshot.data),
      );
    },
  );
}

class DramaTile extends StatelessWidget {
  const DramaTile({
    super.key,
    required this.drama,
    required this.repository,
    required this.onTap,
    this.subtitle,
    this.badge,
    this.selected,
    this.onMore,
    this.onLongPress,
  });
  final Drama drama;
  final AppRepository repository;
  final VoidCallback onTap;

  /// 标题下方元信息行的备选文字（进度、站点名等）。
  final String? subtitle;

  /// 元信息行优先使用的文字（追剧状态、更新提示）。
  final String? badge;
  final bool? selected;
  final VoidCallback? onMore;
  final VoidCallback? onLongPress;

  /// 标题样式：Kazumi 的卡片标题是 14px、w500、letterSpacing 0.3。
  static TextStyle _titleStyle(BuildContext context) {
    final base = Theme.of(context).textTheme.titleSmall;
    return (base ?? const TextStyle()).copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      letterSpacing: .3,
      height: 1.3,
    );
  }

  static TextStyle _metaStyle(BuildContext context) {
    final base = Theme.of(context).textTheme.bodySmall;
    return (base ?? const TextStyle()).copyWith(
      fontSize: 12,
      height: 1.3,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }

  /// 标题最多显示几行。
  ///
  /// 文字区高度是预留的，实际行数由「可用高度 / 行高」算出来（1–3 行）：
  /// 短标题不会在卡片下面撑出一条空白，长标题也不会溢出。Kazumi 用
  /// `TextPainter` 量，这里直接按行高除，省掉每张卡每次布局一个 painter。
  static const int maxTitleLines = 3;

  /// 大字号下标题最多放大到 1.1 倍（Kazumi 同值）。
  ///
  /// 网格的列宽与行高不随字号变，放到 1.3 倍时标题会把海报挤没。
  static const double maxTitleScale = 1.1;

  /// 元信息行高度：一行。只有传了 [subtitle] / [badge] 的页面才预留它。
  static double metaHeight(BuildContext context) {
    final style = _metaStyle(context);
    final line =
        MediaQuery.textScalerOf(context).scale(style.fontSize!) *
        (style.height ?? 1.3);
    return line + 2;
  }

  /// 卡片总高 = 海报（宽 / [Md3Grid.posterRatio]）+ 文字区
  /// （[Md3Grid.textReserve]，随字号缩放）+ 可选的一行元信息。
  ///
  /// [width] 必须是卡片**实际**会被摆成的宽度（见 [Md3Grid.tileWidth]），
  /// 两者不一致时行高会差出几个像素。网格、首屏骨架屏
  /// 都从这里取行高，两者必须给同一个 `withMeta`。
  static double extentFor(
    BuildContext context,
    double width, {
    bool withMeta = false,
  }) =>
      (width / Md3Grid.posterRatio +
              MediaQuery.textScalerOf(context).scale(Md3Grid.textReserve) +
              (withMeta ? metaHeight(context) : 0))
          .ceilToDouble();

  /// 元信息行的文字。目录页两个都不传，因此那里与 Kazumi 一样只有海报和标题。
  String? _metaText() {
    final label = badge;
    if (label != null && label.isNotEmpty) return label;
    // 与分类重复的副标题不占行：分类在筛选条里已经给过了。
    final extra = subtitle;
    if (extra != null && extra.isNotEmpty && extra != drama.category) {
      return extra;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final meta = _metaText();
    // Kazumi 的卡片就是 `Card(elevation: 0, margin: 0)`：一张海报加标题，
    // 无阴影、无叠字，层级全靠 surfaceContainerLow 与内容书架底色的明度差。
    final content = Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: Md3Shape.poster),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: Md3Grid.posterRatio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 与参照应用 `BangumiCardV` 一致：海报本身参与 Hero 转场，
                // 详情页用同一个标签 'cover-${drama.id}' 接住。
                DramaCover(
                  drama: drama,
                  repository: repository,
                  heroTag: 'cover-${drama.id}',
                ),
                if (selected != null)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: selected!
                          ? colors.primary
                          : Colors.black.withValues(alpha: .64),
                      child: Icon(
                        selected! ? Icons.check_rounded : Icons.circle_outlined,
                        size: 22,
                        color: selected! ? colors.onPrimary : Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 文字区只有预留的 [Md3Grid.textReserve] 高，标题在里面按可用
          // 高度算行数（1–3 行），因此短标题不撑空白、长标题不溢出。
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(5, 3, 5, 1),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final style = _titleStyle(context);
                  final scaler = MediaQuery.textScalerOf(
                    context,
                  ).clamp(maxScaleFactor: maxTitleScale);
                  final line =
                      scaler.scale(style.fontSize!) * (style.height ?? 1.3);
                  final lines = constraints.maxHeight <= 0
                      ? 1
                      : (constraints.maxHeight / line).floor().clamp(
                          1,
                          maxTitleLines,
                        );
                  return Text(
                    drama.title,
                    maxLines: lines,
                    overflow: TextOverflow.ellipsis,
                    textScaler: scaler,
                    style: style,
                  );
                },
              ),
            ),
          ),
          if (meta != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(5, 0, 5, 3),
              child: SizedBox(
                height: metaHeight(context),
                child: Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _metaStyle(context),
                ),
              ),
            ),
        ],
      ),
    );
    return _HoverTile(
      onTap: onTap,
      onLongPress: onLongPress ?? onMore,
      onSecondaryTap: onMore,
      selected: selected ?? false,
      // 元信息行不再叠在封面上，因此朗读内容要显式带上它，否则屏幕
      // 阅读器只能读到标题。
      semanticLabel: AppLocalizations.of(context).dramaSemantic(
        drama.title,
        drama.episodes,
        meta == null ? '' : '，$meta',
      ),
      child: content,
    );
  }
}

/// 桌面端卡片的 hover / focus 反馈。
///
/// 三件事：
/// - 鼠标悬停时封面轻微放大并加一圈描边，提示「这是可点的」；
/// - 键盘 Tab 聚焦时用 2px 主色环；
/// - 按压缩放 0.98，给点击一个物理感。
///
/// 全部受 `MediaQuery.disableAnimationsOf` 控制。
class _HoverTile extends StatefulWidget {
  const _HoverTile({
    required this.child,
    required this.selected,
    required this.semanticLabel,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
  });

  final Widget child;
  final bool selected;
  final String semanticLabel;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;

  @override
  State<_HoverTile> createState() => _HoverTileState();
}

class _HoverTileState extends State<_HoverTile> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final duration = Md3Motion.of(context, Md3Motion.shape);
    final borderColor = _focused
        ? colors.primary
        : _hovered
        ? colors.outline
        : Colors.transparent;
    final scale = _pressed ? .98 : 1.0;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.semanticLabel,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: FocusableActionDetector(
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          child: Listener(
            onPointerDown: (_) => setState(() => _pressed = true),
            onPointerUp: (_) => setState(() => _pressed = false),
            onPointerCancel: (_) => setState(() => _pressed = false),
            child: GestureDetector(
              onSecondaryTap: widget.onSecondaryTap,
              child: InkWell(
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
                borderRadius: Md3Shape.poster,
                hoverColor: colors.onSurface.withValues(alpha: Md3State.hover),
                child: AnimatedScale(
                  scale: scale,
                  duration: duration,
                  curve: Md3Motion.standardCurve,
                  child: AnimatedContainer(
                    duration: duration,
                    curve: Md3Motion.standardCurve,
                    decoration: BoxDecoration(
                      borderRadius: Md3Shape.poster,
                      border: Border.all(
                        color: borderColor,
                        width: _focused ? 2 : 1,
                      ),
                    ),
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class StatusPanel extends StatelessWidget {
  const StatusPanel({
    super.key,
    required this.title,
    this.message = '',
    this.onRetry,
    this.icon = Icons.movie_filter_outlined,
    this.action,
    this.secondaryAction,
  });
  final String title;
  final String message;
  final VoidCallback? onRetry;
  final IconData icon;
  final String? action;
  final Widget? secondaryAction;
  @override
  Widget build(BuildContext context) => EmptyState(
    title: title,
    message: message,
    icon: icon,
    actions: [
      if (onRetry != null)
        FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(action ?? AppLocalizations.of(context).retry),
        ),
      ?secondaryAction,
    ],
  );
}

/// 海报网格的 delegate：列数、间距与行高全部来自 [Md3Grid] 与
/// [DramaTile.extentFor]，页面不要再自己算列数。
///
/// [width] 应当是**已扣除页面留白**的内容宽度（见
/// [Md3Spacing.contentInset]）；首屏骨架用同一组值算占位，
/// 数据到位时才不会跳版。
SliverGridDelegate dramaGridDelegate(
  BuildContext context,
  double width, {
  bool withMeta = false,
}) {
  final columns = Md3Grid.columns(width);
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    mainAxisSpacing: Md3Grid.rowSpacing,
    crossAxisSpacing: Md3Grid.spacing,
    mainAxisExtent: DramaTile.extentFor(
      context,
      Md3Grid.tileWidth(width, columns),
      withMeta: withMeta,
    ),
  );
}

String formatPosition(double seconds) {
  final value = seconds.isFinite ? seconds.toInt().clamp(0, 999999) : 0;
  return '${value ~/ 60}:${(value % 60).toString().padLeft(2, '0')}';
}
