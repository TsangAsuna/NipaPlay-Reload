import 'package:flutter/material.dart';
import 'package:nipaplay/utils/video_player_state.dart';
import 'package:provider/provider.dart';

class ExternalSubtitleOverlay extends StatefulWidget {
  final double currentPositionMs;

  const ExternalSubtitleOverlay({
    super.key,
    required this.currentPositionMs,
  });

  @override
  State<ExternalSubtitleOverlay> createState() => _ExternalSubtitleOverlayState();
}

class _ExternalSubtitleOverlayState extends State<ExternalSubtitleOverlay> {
  /// 长按后显示编辑框（带锁定键）
  bool _boxVisible = false;
  /// 锁定后位置不可拖动，锁键隐藏；点击字幕解锁
  bool _locked = false;
  /// 字幕背景（功能区按钮切换；默认无背景）
  bool _subtitleBgEnabled = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<VideoPlayerState>(
      builder: (context, videoState, _) {
        if (!videoState.shouldRenderCurrentExternalSubtitleInApp()) {
          return const SizedBox.shrink();
        }

        final isSrt = videoState.currentExternalSubtitleIsSrt;
        final subtitleTimeMs = widget.currentPositionMs -
            (isSrt
                ? videoState.srtSubtitleDelaySeconds
                : videoState.subtitleDelaySeconds) *
                1000;
        final subtitleText =
            videoState.getCurrentExternalSubtitleTextAt(subtitleTimeMs.round());

        if (subtitleText.trim().isEmpty || videoState.subtitleOpacity <= 0) {
          return const SizedBox.shrink();
        }

        // SRT 叠层可拖动/缩放调整（水平 margin、垂直 position）；ASS 保持只读
        final draggable = isSrt;
        return IgnorePointer(
          ignoring: !draggable,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : MediaQuery.of(context).size.width;
              final baseFontSize = (width * 0.03).clamp(18.0, 42.0).toDouble();
              final fontSize = (baseFontSize * videoState.subtitleScale)
                  .clamp(14.0, 72.0)
                  .toDouble();

              final fillStyle = TextStyle(
                fontSize: fontSize,
                fontWeight:
                    videoState.subtitleBold ? FontWeight.bold : FontWeight.w500,
                fontStyle: videoState.subtitleItalic
                    ? FontStyle.italic
                    : FontStyle.normal,
                color: videoState.subtitleColor,
                height: 1.28,
                fontFamily: videoState.subtitleFontName.isNotEmpty
                    ? videoState.subtitleFontName.split(',').first.trim()
                    : null,
                // 多选字体时其余作 fallback
                fontFamilyFallback:
                    videoState.subtitleFontName.contains(',')
                        ? videoState.subtitleFontName
                            .split(',')
                            .skip(1)
                            .map((e) => e.trim())
                            .where((e) => e.isNotEmpty)
                            .toList()
                        : null,
                shadows: videoState.subtitleShadowOffset > 0
                    ? [
                        Shadow(
                          color: videoState.subtitleShadowColor,
                          offset: Offset(0, videoState.subtitleShadowOffset),
                          blurRadius: videoState.subtitleShadowOffset * 2,
                        ),
                      ]
                    : null,
              );

              final borderPaint = Paint()
                ..style = PaintingStyle.stroke
                ..strokeJoin = StrokeJoin.round
                ..strokeWidth =
                    videoState.subtitleBorderSize.clamp(0.0, 8.0).toDouble()
                ..color = videoState.subtitleBorderColor;

              final borderStyle = fillStyle.copyWith(
                foreground: borderPaint,
                color: null,
                shadows: null,
              );

              // 文本层：ConstrainedBox + 字幕文本（不含定位/拖拽手势）
                            final Widget textBox = ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: width * 0.9),
                              child: _subtitleBgEnabled
                                  ? Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: const Color(0x99000000),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: _OutlinedSubtitleText(
                                        text: subtitleText,
                                        fillStyle: fillStyle,
                                        borderStyle: borderStyle,
                                        showBorder:
                                            videoState.subtitleBorderSize > 0,
                                        textAlign:
                                            _resolveTextAlign(videoState.subtitleAlignX),
                                      ),
                                    )
                                  : _OutlinedSubtitleText(
                                      text: subtitleText,
                                      fillStyle: fillStyle,
                                      borderStyle: borderStyle,
                                      showBorder: videoState.subtitleBorderSize > 0,
                                      textAlign:
                                          _resolveTextAlign(videoState.subtitleAlignX),
                                    ),
                            );

                            // SRT 拖动交互：
                            // - 未锁定时单指拖动字幕 -> 显示编辑框并调整位置（水平 marginX / 垂直 position）
                            // - 点锁定键 -> 锁定并消除编辑框（位置冻结）
                            // - 锁定后点击字幕 -> 解锁并重新显示编辑框
                            // 长按不再出框；未锁定时点击字幕不收起编辑框（避免“点空域关框”歧义）。
                            // 手势只包文本层：命中区限定在字幕周围，避免全屏拦截暂停等触摸。
                            // 用 Pan（单指）拖动：与音量/亮度 VerticalDrag 在竞技场竞争，
                            // 拖动激活后置 subtitleDragActive 屏蔽音量/亮度/进度手势。
                            // 命中区限定在字幕文本层（nPlayer subtitleContainsPoint 语义）：
                            // 按到文本才开始拖动；框内 padding 空域不触发拖动，避免误拖。
                            // 未锁定可拖（水平 marginX / 垂直 position，1:1 舞台映射可入黑边）；
                            // 点锁定键 -> 锁定并消除编辑框；锁定后点字幕 -> 解锁出框。
                            // 拖动激活期间置 subtitleDragActive 屏蔽音量/亮度/进度手势。
                            Widget textHitArea = GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onLongPressStart: (_) {
                                // 长按字幕 -> 出框（子层长按赢过父层长按倍速；有框时父层已被禁）
                                if (!_boxVisible) {
                                  setState(() {
                                    _locked = false;
                                    _boxVisible = true;
                                  });
                                  videoState.setSubtitleEditBoxVisible(true);
                                }
                              },
                              onPanStart: _locked
                                  ? null
                                  : (details) {
                                      videoState.setSubtitleDragActive(true);
                                      if (!_boxVisible) {
                                        setState(() => _boxVisible = true);
                                        videoState.setSubtitleEditBoxVisible(true);
                                      }
                                    },
                              onPanUpdate: _locked
                                  ? null
                                  : (details) {
                                      final v = videoState;
                                      v.setSubtitleMarginX(
                                        v.subtitleMarginX + details.delta.dx,
                                      );
                                      // 垂直：按舞台高度 1:1 映射到 0~100（可拖到视频外黑边区）
                                      final stageH = constraints.maxHeight.isFinite
                                          ? constraints.maxHeight
                                          : MediaQuery.of(context).size.height;
                                      v.setSubtitlePosition(
                                        (v.subtitlePosition +
                                                details.delta.dy / stageH * 100)
                                            .clamp(
                                              VideoPlayerState.minSubtitlePosition,
                                              VideoPlayerState.maxSubtitlePosition,
                                            )
                                            .toDouble(),
                                      );
                                    },
                              onPanEnd: _locked
                                  ? null
                                  : (_) {
                                      videoState.setSubtitleDragActive(false);
                                    },
                              onPanCancel: _locked
                                  ? null
                                  : () {
                                      videoState.setSubtitleDragActive(false);
                                    },
                              child: textBox,
                            );

                            Widget positionedContent = draggable
                                ? GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTapUp: (_) {
                                      if (_locked) {
                                        // 锁定时点击字幕 -> 解锁并重新显示编辑框
                                        setState(() {
                                          _locked = false;
                                          _boxVisible = true;
                                        });
                                      }
                                    },
                                    child: _boxVisible
                                        ? Transform.translate(
                                            offset: const Offset(-24, -24),
                                            child: Padding(
                                              padding: const EdgeInsets.all(24),
                                              child: Stack(
                                                clipBehavior: Clip.none,
                                                children: [
                                                  // 文本 + 虚线边框层（只圈住字幕文本区域；拖动只从文本触发）
                                                  Stack(
                                                    clipBehavior: Clip.none,
                                                    children: [
                                                      textHitArea,
                                                      Positioned.fill(
                                                        child: IgnorePointer(
                                                          child: Container(
                                                            decoration: BoxDecoration(
                                                              border: Border.all(
                                                                color: _locked
                                                                    ? const Color(0x99FFD54F)
                                                                    : const Color(0x99FFFFFF),
                                                                width: 1,
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  // 背景切换键（字幕框左上外角）
                                                  Positioned(
                                                    left: 0,
                                                    top: 0,
                                                    child: GestureDetector(
                                                      behavior: HitTestBehavior.opaque,
                                                      onTap: () {
                                                        setState(() {
                                                          _subtitleBgEnabled =
                                                              !_subtitleBgEnabled;
                                                        });
                                                      },
                                                      child: Icon(
                                                        _subtitleBgEnabled
                                                            ? Icons.format_color_fill
                                                            : Icons.format_color_reset_outlined,
                                                        size: 22,
                                                        color: const Color(0xFFFFFFFF),
                                                        shadows: const [
                                                          Shadow(
                                                              blurRadius: 4,
                                                              color: Colors.black),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                  // 锁定键：未锁定显示（点它锁定）；锁定后隐藏
                                                  if (!_locked)
                                                    Positioned(
                                                      right: 0,
                                                      top: 0,
                                                      child: GestureDetector(
                                                        behavior: HitTestBehavior.opaque,
                                                        onTap: () {
                                                          // 锁定并消除编辑框（位置冻结）
                                                          setState(() {
                                                            _locked = true;
                                                            _boxVisible = false;
                                                            videoState.setSubtitleEditBoxVisible(false);
                                                          });
                                                        },
                                                        child: const Icon(
                                                          Icons.lock_outline,
                                                          size: 22,
                                                          color: Color(0xFFFFD54F),
                                                          shadows: [
                                                            Shadow(
                                                                blurRadius: 4,
                                                                color: Colors.black),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          )
                                        : textHitArea,
                                  )
                                : textBox;


                            Widget content = Opacity(
                              opacity:
                                  videoState.subtitleOpacity.clamp(0.0, 1.0).toDouble(),
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 24 + videoState.subtitleMarginX,
                                  vertical: 16 + videoState.subtitleMarginY,
                                ),
                                child: Align(
                                  alignment: Alignment(
                                    _resolveHorizontalAlignment(videoState.subtitleAlignX),
                                    _resolveVerticalAlignment(videoState.subtitlePosition),
                                  ),
                                  child: positionedContent,
                                ),
                              ),
                            );

              return content;
            },
          ),
        );
      },
    );
  }

  double _resolveHorizontalAlignment(SubtitleAlignX alignX) {
    switch (alignX) {
      case SubtitleAlignX.left:
        return -1;
      case SubtitleAlignX.center:
        return 0;
      case SubtitleAlignX.right:
        return 1;
    }
  }

  TextAlign _resolveTextAlign(SubtitleAlignX alignX) {
    switch (alignX) {
      case SubtitleAlignX.left:
        return TextAlign.left;
      case SubtitleAlignX.center:
        return TextAlign.center;
      case SubtitleAlignX.right:
        return TextAlign.right;
    }
  }

  double _resolveVerticalAlignment(double subtitlePosition) {
    final normalized = subtitlePosition.clamp(
      VideoPlayerState.minSubtitlePosition,
      VideoPlayerState.maxSubtitlePosition,
    );
    // 0=屏幕顶 100=屏幕底，允许拖到视频外（黑边区）：overlay 是 Positioned.fill
    // 占满整个播放舞台（含视频外区域），视频面 Center(AspectRatio) 居中留黑边。
    return (normalized / 100) * 2.0 - 1.0;
  }
}

class _OutlinedSubtitleText extends StatelessWidget {
  final String text;
  final TextStyle fillStyle;
  final TextStyle borderStyle;
  final bool showBorder;
  final TextAlign textAlign;

  const _OutlinedSubtitleText({
    required this.text,
    required this.fillStyle,
    required this.borderStyle,
    required this.showBorder,
    required this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    final fillText = Text(
      text,
      textAlign: textAlign,
      softWrap: true,
      style: fillStyle,
    );

    if (!showBorder) {
      return fillText;
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        Text(
          text,
          textAlign: textAlign,
          softWrap: true,
          style: borderStyle,
        ),
        fillText,
      ],
    );
  }
}
