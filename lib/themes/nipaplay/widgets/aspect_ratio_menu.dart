import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:nipaplay/utils/video_player_state.dart';
import 'arrow_menu_container.dart';
import 'player_menu_theme.dart';

/// 画面比例菜单（NipaPlay 主题、PiLiPlus 式紧凑下拉）。
///
/// 锚定改用 CompositedTransformTarget/Follower（LayerLink）——Flutter 官方
/// 变换自适应锚定，不再手算全局坐标 + UiScaleWrapper 换算，面板始终贴住
/// 画面比例按钮（修复此前浮到弹幕按钮/位置漂移）；点击面板外部自动关闭；
/// 选项文字居中对齐。仅换 Nipa 背景（ArrowMenuContainer + PlayerMenuTheme）。
class AspectRatioMenu extends StatelessWidget {
  const AspectRatioMenu({
    super.key,
    required this.onClose,
    this.layerLink,
    this.panelOffset = const Offset(0, 0),
    this.standaloneWindow = false,
  });

  final VoidCallback onClose;

  /// 与按钮上的 CompositedTransformTarget 成对（主窗口锚定）。
  final LayerLink? layerLink;

  /// 相对按钮左上角的偏移（在 _showAspectMenu 按上下空间计算，贴按钮下/上方）。
  final Offset panelOffset;

  final bool standaloneWindow;

  /// 面板宽度：仅容纳勾选图标 + 最长选项（"16:9"）文字。
  static const double menuWidth = 96;

  /// 面板高度：贴合 9 个紧凑选项。
  static const double menuHeight = 336;

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
  Widget build(BuildContext context) {
    final panel = _buildPanel(context);

    Widget panelShell() {
      return ArrowMenuContainer(
        backgroundColor: PlayerMenuTheme.colorsOf(context).surface,
        borderColor: PlayerMenuTheme.colorsOf(context).border,
        blurValue: 0,
        borderRadius: 15,
        showPointer: false,
        pointUp: true,
        pointerX: menuWidth / 2,
        pointerWidth: 16,
        pointerHeight: 8,
        contentPadding: EdgeInsets.zero,
        shadows: [
          BoxShadow(
            color: PlayerMenuTheme.colorsOf(context).shadow,
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
        child: SizedBox(
          width: menuWidth,
          height: menuHeight,
          child: panel,
        ),
      );
    }

    // 独立窗口（detached player 弹窗）或未提供 LayerLink：直接渲染面板。
    if (standaloneWindow || layerLink == null) {
      return panelShell();
    }

    // 主窗口：LayerLink 锚定 + 点击面板外部关闭（全屏透明遮罩）。
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onClose,
            ),
          ),
          Positioned.fill(
            child: CompositedTransformFollower(
              link: layerLink!,
              showWhenUnlinked: false,
              offset: panelOffset,
              child: panelShell(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPanel(BuildContext context) {
    final menuColors = PlayerMenuTheme.colorsOf(context);
    return Consumer<VideoPlayerState>(
      builder: (context, videoState, _) {
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
                  onClose();
                },
              ),
          ],
        );
      },
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
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: menuColors.divider, width: 0.5),
            ),
          ),
          // 文字在 96px 面板内水平居中；勾选图标内联在文字左侧，
          // 不占固定占位（修复整体偏右）。
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) ...[
                  Icon(
                    Icons.check,
                    size: 16,
                    color: menuColors.selectedForeground,
                  ),
                  const SizedBox(width: 4),
                ],
                Text(
                  label,
                  style: TextStyle(
                    color: selected
                        ? menuColors.selectedForeground
                        : menuColors.foreground,
                    fontSize: 14,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}