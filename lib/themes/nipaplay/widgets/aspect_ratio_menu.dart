import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:nipaplay/utils/video_player_state.dart';
import 'base_settings_menu.dart';
import 'player_menu_theme.dart';

/// 画面比例菜单（NipaPlay 主题、PiLiPlus 式紧凑下拉）。
///
/// 对齐 PiLiPlus 的交互：
/// - 无标题栏、无右上角关闭按钮（showHeader=false），点击外部/选择即关闭；
/// - 窄面板贴合按钮下拉，选项紧凑、文字右侧不空出大片留白；
/// - 面板左缘对齐按钮左缘（由 anchorKey 解析并做 UiScaleWrapper 坐标归一化，
///   避免浮到错误位置）。
///
/// 保留 NipaPlay 视觉风格：BaseSettingsMenu 圆角面板 + PlayerMenuTheme 配色，
/// 当前模式高亮并带勾选标记。
class AspectRatioMenu extends StatefulWidget {
  const AspectRatioMenu({
    super.key,
    required this.onClose,
    this.anchorRect,
    this.anchorKey,
    this.standaloneWindow = false,
  });

  final VoidCallback onClose;
  final Rect? anchorRect;
  final GlobalKey? anchorKey;
  final bool standaloneWindow;

  /// 面板宽度：仅容纳勾选图标 + 最长选项（"16:9"）文字，避免大片空余。
  static const double menuWidth = 104;

  /// 面板高度：9 个紧凑选项。
  static const double menuHeight = 370;

  @override
  State<AspectRatioMenu> createState() => _AspectRatioMenuState();
}

class _AspectRatioMenuState extends State<AspectRatioMenu> {
  Rect? _anchorRect;
  bool _loggedResolvedAnchor = false;

  static const double _menuRightOffset = 14;

  static const Map<VideoAspectMode, String> _labels = {
    VideoAspectMode.contain: '适应',
    VideoAspectMode.cover: '裁剪',
    VideoAspectMode.fill: '拉伸',
    VideoAspectMode.fitWidth: '等宽',
    VideoAspectMode.fitHeight: '等高',
    VideoAspectMode.none: '原始',
    VideoAspectMode.scaleDown: '限制',
    VideoAspectMode.ratio16x9: '16:9',
    VideoAspectMode.ratio4x3: '4:3',
  };

  @override
  void initState() {
    super.initState();
    _anchorRect = widget.anchorRect;
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshAnchorRect());
  }

  @override
  void didUpdateWidget(AspectRatioMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.anchorRect != oldWidget.anchorRect ||
        widget.anchorKey != oldWidget.anchorKey) {
      _anchorRect = widget.anchorRect ?? _anchorRect;
      WidgetsBinding.instance.addPostFrameCallback((_) => _refreshAnchorRect());
    }
  }

  void _refreshAnchorRect() {
    if (!mounted) return;
    final resolved = _resolveAnchorRectFromKey();
    if (resolved == null) return;
    if (_anchorRect != resolved) {
      setState(() {
        _anchorRect = resolved;
      });
    }
  }

  Rect? _resolveAnchorRectFromKey() {
    final context = widget.anchorKey?.currentContext;
    if (context == null) return null;
    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return null;
    return renderBox.localToGlobal(Offset.zero) & renderBox.size;
  }

  Rect? _resolveAnchorRect() {
    final Rect? resolved = _anchorRect ?? _resolveAnchorRectFromKey();
    if (resolved == null) return null;
    return _normalizeAnchorRect(resolved);
  }

  Rect _normalizeAnchorRect(Rect rect) {
    // UiScaleWrapper 会缩放 MediaQuery 尺寸，需把全局坐标归一化到布局空间，
    // 否则下拉面板会浮到错误位置（与 VideoSettingsMenu 同一处理方式）。
    final mediaSize = MediaQuery.of(context).size;
    if (mediaSize.width == 0 || mediaSize.height == 0) {
      return rect;
    }
    final view = View.of(context);
    final viewSize = view.physicalSize / view.devicePixelRatio;
    final double scaleX = viewSize.width / mediaSize.width;
    final double scaleY = viewSize.height / mediaSize.height;
    if (!scaleX.isFinite ||
        !scaleY.isFinite ||
        scaleX <= 0 ||
        scaleY <= 0 ||
        ((scaleX - 1.0).abs() < 0.001 && (scaleY - 1.0).abs() < 0.001)) {
      return rect;
    }
    return Rect.fromLTWH(
      rect.left / scaleX,
      rect.top / scaleY,
      rect.width / scaleX,
      rect.height / scaleY,
    );
  }

  @override
  Widget build(BuildContext context) {
    final Rect? resolvedAnchorRect = _resolveAnchorRect();
    if (!_loggedResolvedAnchor && resolvedAnchorRect != null) {
      assert(() {
        debugPrint('AspectRatioMenu: resolvedAnchorRect=$resolvedAnchorRect');
        return true;
      }());
      _loggedResolvedAnchor = true;
    }

    // PiLiPlus 式下拉定位：面板左缘对齐按钮左缘（0 宽锚点 + 半宽偏移让居中算法归零），
    // 面板贴按钮下方/上方。
    final Rect? anchorRect = resolvedAnchorRect == null
        ? null
        : Rect.fromLTWH(
            resolvedAnchorRect.left + (AspectRatioMenu.menuWidth / 2),
            resolvedAnchorRect.top,
            0,
            resolvedAnchorRect.height,
          );

    final menu = BaseSettingsMenu(
      title: '画面比例',
      onClose: widget.onClose,
      width: AspectRatioMenu.menuWidth,
      rightOffset: _menuRightOffset,
      height: AspectRatioMenu.menuHeight,
      content: Consumer<VideoPlayerState>(
        builder: (context, videoState, _) {
          final menuColors = PlayerMenuTheme.colorsOf(context);
          final current = videoState.videoAspectMode;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final mode in VideoAspectMode.values)
                _buildItem(
                  menuColors: menuColors,
                  label: _labels[mode] ?? mode.name,
                  selected: mode == current,
                  onTap: () {
                    unawaited(videoState.setVideoAspectMode(mode));
                    widget.onClose();
                  },
                ),
            ],
          );
        },
      ),
    );

    return SettingsMenuScope(
      width: AspectRatioMenu.menuWidth,
      rightOffset: _menuRightOffset,
      // 与 PiLiPlus 一致：不显示标题栏/右上角关闭按钮
      showHeader: false,
      lockControlsVisible: true,
      anchorRect: anchorRect,
      // PiLiPlus 式紧凑下拉：不画指针箭头，面板直接贴按钮下方
      showPointer: false,
      height: AspectRatioMenu.menuHeight,
      requestClose: () async => widget.onClose(),
      standaloneWindow: widget.standaloneWindow,
      child: menu,
    );
  }

  Widget _buildItem({
    required PlayerMenuColors menuColors,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? menuColors.selectedBackground : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: menuColors.divider, width: 0.5),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected)
                Icon(
                  Icons.check,
                  size: 18,
                  color: menuColors.selectedForeground,
                )
              else
                const SizedBox(width: 18),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  color: selected
                      ? menuColors.selectedForeground
                      : menuColors.foreground,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}