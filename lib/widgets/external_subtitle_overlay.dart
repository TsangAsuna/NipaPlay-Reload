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

                            // SRT 拖动交互（nPlayer 式）：
                            // - 长按字幕 -> 显示编辑框 + 锁定键
                            // - 未锁定时可自由拖动（水平 marginX / 垂直 position）
                            // - 点锁定键 -> 锁定（位置冻结，锁键隐藏）
                            // - 锁定后点击字幕 -> 解锁并重新显示锁键
                            // 手势只包文本层：命中区限定在字幕周围，避免全屏拦截暂停等触摸。
                            Widget positionedContent = draggable
                                ? GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onLongPressStart: (_) {
                                      if (!_boxVisible) {
                                        setState(() => _boxVisible = true);
                                      }
                                    },
                                    onTapUp: (_) {
                                      if (_locked) {
                                        // 锁定时点击字幕 -> 解锁并显示锁键
                                        setState(() {
                                          _locked = false;
                                          _boxVisible = true;
                                        });
                                      } else {
                                        // 未锁定时点击字幕 -> 收起编辑框
                                        if (_boxVisible) {
                                          setState(() => _boxVisible = false);
                                        }
                                      }
                                    },
                                    onScaleStart: _locked
                                        ? null
                                        : (details) {
                                            // 超过设置的最大手指数（1=单指 2=双指）不响应拖动
                                            if (details.pointerCount >
                                                videoState.subtitleDragFingers) {
                                              return;
                                            }
                                            if (!_boxVisible) {
                                              setState(() => _boxVisible = true);
                                            }
                                          },
                                    onScaleUpdate: _locked
                                        ? null
                                        : (details) {
                                            final v = videoState;
                                            if (details.pointerCount >
                                                v.subtitleDragFingers) {
                                              return;
                                            }
                                            v.setSubtitleMarginX(
                                              v.subtitleMarginX + details.focalPointDelta.dx,
                                            );
                                            v.setSubtitlePosition(
                                              (v.subtitlePosition +
                                                      details.focalPointDelta.dy / 4)
                                                  .clamp(
                                                    VideoPlayerState.minSubtitlePosition,
                                                    VideoPlayerState.maxSubtitlePosition,
                                                  )
                                                  .toDouble(),
                                            );
                                          },
                                    child: _boxVisible
                                        ? Transform.translate(
                                            offset: const Offset(-18, -18),
                                            child: Padding(
                                              padding: const EdgeInsets.all(18),
                                              child: Stack(
                                                clipBehavior: Clip.none,
                                                children: [
                                                  // 文本 + 虚线边框层（只圈住字幕文本区域）
                                                  Stack(
                                                    clipBehavior: Clip.none,
                                                    children: [
                                                      textBox,
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
                                                          setState(() => _locked = true);
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
                                        : textBox,
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
