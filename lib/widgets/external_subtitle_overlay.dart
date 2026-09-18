import 'dart:async';
import 'dart:io';

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
  /// 可见性以 VideoPlayerState 为准做初始化：叠层子树在自愈重开/进出
  /// 播放页等场景会被整体重建，若用硬编码默认值，编辑框会"自己冒出来"。
  late bool _boxVisible;   // 常驻框：锁定后消失，再次长按出现
  /// 锁定后位置不可拖动，锁键隐藏；点击字幕解锁
  late bool _locked;
  bool _longPressMoved = false;  // 长按期间是否发生拖动
  bool _panDragActive = false;  // Pan fallback: 长按未识别前移动也能拖
  double _dragStartPosition = 100.0;  // 长按起点字幕垂直位置
  double _dragStartMarginX = 0.0;    // 长按起点水平边距
  /// 字幕背景（功能区按钮切换；默认无背景）
  bool _subtitleBgEnabled = false;
  Timer? _twoFingerTimer;  // 双指长按识别定时器
  // 字幕轴同步诊断去重
  String _lastLoggedCueKey = '';
  int _lastSyncLogAtMs = 0;
  static const int _syncLogMinIntervalMs = 1000;

  @override
  void initState() {
    super.initState();
    final videoState =
        Provider.of<VideoPlayerState>(context, listen: false);
    _boxVisible = videoState.subtitleEditBoxVisible;
    _locked = !_boxVisible;
  }

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

        // 字幕轴同步诊断：每条字幕首次显示时记录一次内核、原始播放器位置、
        // 平滑时钟与实际查表时间，用于定位内核间（MDK vs libmpv）的轴偏移
        // 是来自位置源还是平滑时钟。
        _logSubtitleSyncOnce(
          videoState: videoState,
          cueKey: subtitleText,
          subtitleTimeMs: subtitleTimeMs.round(),
        );

        if (subtitleText.trim().isEmpty || videoState.subtitleOpacity <= 0) {
          return const SizedBox.shrink();
        }

        // SRT 叠层可拖动/缩放调整（水平 margin、垂直 position）；ASS 保持只读
        // 所有 App 叠层外挂字幕（SRT/VTT/ASS/SSA）都可长按拖动位置
        final draggable = videoState.shouldRenderCurrentExternalSubtitleInApp();
        return IgnorePointer(
          ignoring: !draggable,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : MediaQuery.of(context).size.width;
              final baseFontSize = (width * 0.03).clamp(18.0, 42.0).toDouble();
              final fontSize = (baseFontSize *
                  videoState.srtSubtitleScale)
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
                              constraints: BoxConstraints(
                              minWidth: 120, maxWidth: width * 0.9),
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

                            // SRT 拖动交互（libmpv 实测版）：
                            // - 命中区：textBox + 16px padding（结构恒定，出框不跳；框外按钮/手柄独立可点）
                            // - 长按按住 -> 出框进入编辑态；拖动中置 subtitleDragActive 屏蔽音量/亮度/进度手势
                            // - 长按后拖动 -> 手指可移出字幕继续拖动（水平 marginX / 垂直 position）
                            // - 长按抬起：有拖动 -> 锁定收框；原地长按 -> 保持框（双指长按/设置钮弹面板）
                            // - 点框内（非按钮/手柄处）-> 取消框
                            // - 右下角拉伸柄/左上设置/右上背景按钮独立可点（在拖动 GestureDetector 外）
                            Widget positionedContent;
                            if (!draggable) {
                              positionedContent = textBox;
                            } else {
                              final Widget dragArea = GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapUp: (_) {
                                  // 点击框内非按钮处 -> 取消框
                                  if (_boxVisible) {
                                    setState(() {
                                      _locked = true;
                                      _boxVisible = false;
                                    });
                                    videoState.setSubtitleEditBoxVisible(false);
                                  }
                                },
                                onPanDown: (_) {
                                  _panDragActive = false;
                                },
                                onPanUpdate: (details) {
                                  // 长按已 accept（_longPressMoved 由 LongPress 路径管）则不重复处理
                                  if (_longPressMoved) return;
                                  if (!_boxVisible && !_panDragActive) {
                                    // 首次移动：出框并记录起点
                                    _panDragActive = true;
                                    _dragStartPosition = videoState.subtitlePosition;
                                    _dragStartMarginX = videoState.subtitleMarginX;
                                    setState(() { _boxVisible = true; });
                                  }
                                  if (!_panDragActive) return;
                                  final v = videoState;
                                  _dragStartMarginX += details.delta.dx;
                                  v.setSubtitleMarginX(
                                    _dragStartMarginX.clamp(-500.0, 500.0),
                                  );
                                  final stageH = MediaQuery.of(context).size.height;
                                  _dragStartPosition += details.delta.dy / stageH * 100;
                                  v.setSubtitlePosition(
                                    _dragStartPosition
                                        .clamp(VideoPlayerState.minSubtitlePosition, VideoPlayerState.maxSubtitlePosition)
                                        .toDouble(),
                                  );
                                },
                                onPanEnd: (_) {
                                  if (_panDragActive) {
                                    _panDragActive = false;
                                    videoState.setSubtitleDragActive(false);
                                    setState(() { _locked = true; _boxVisible = false; });
                                    videoState.setSubtitleEditBoxVisible(false);
                                  }
                                },
                                onLongPressStart: (details) {
                                  debugPrint('[SubtitleOverlay] 长按开始');
                                  _longPressMoved = false;
                                  _dragStartPosition = videoState.subtitlePosition;
                                  _dragStartMarginX = videoState.subtitleMarginX;
                                  videoState.setSubtitleDragActive(true);
                                  if (!_boxVisible) {
                                    setState(() {
                                      _boxVisible = true;
                                    });
                                    videoState.setSubtitleEditBoxVisible(true);
                                  }
                                },
                                onLongPressMoveUpdate: (details) {
                                  if (details.offsetFromOrigin.distance > 8) {
                                    _longPressMoved = true;
                                  }
                                  if (!_longPressMoved) return;
                                  final v = videoState;
                                  // 用起点+累计偏移，避免 position+offset 反复叠加导致拖不到底
                                  v.setSubtitleMarginX(
                                    (_dragStartMarginX +
                                            details.offsetFromOrigin.dx)
                                        .clamp(-500.0, 500.0),
                                  );
                                  final stageH =
                                      MediaQuery.of(context).size.height;
                                  v.setSubtitlePosition(
                                    (_dragStartPosition +
                                            details.offsetFromOrigin.dy /
                                                stageH *
                                                100)
                                        .clamp(
                                          VideoPlayerState.minSubtitlePosition,
                                          VideoPlayerState.maxSubtitlePosition,
                                        )
                                        .toDouble(),
                                  );
                                },
                                onLongPressEnd: (_) {
                                  videoState.setSubtitleDragActive(false);
                                  if (_longPressMoved) {
                                    // 拖动过 -> 松手即锁定（位置冻结，收框）
                                    setState(() {
                                      _locked = true;
                                      _boxVisible = false;
                                    });
                                    videoState.setSubtitleEditBoxVisible(false);
                                  } else {
                                    // 原地长按 -> 保持框（双指长按/设置钮弹面板）
                                    videoState.setSubtitleEditBoxVisible(true);
                                  }
                                },
                                // 双指长按：弹 SRT 设置面板（延迟滑块+输入联动、字体、颜色）
                                onScaleStart: (details) {
                                  if (details.pointerCount >= 2) {
                                    _twoFingerTimer?.cancel();
                                    _twoFingerTimer = Timer(
                                      const Duration(milliseconds: 450),
                                      () {
                                        debugPrint('[SubtitleOverlay] 双指长按触发设置面板');
                                        _showSrtSettingsPanel(context, videoState);
                                      },
                                    );
                                  }
                                },
                                onScaleUpdate: (_) {
                                  _twoFingerTimer?.cancel();
                                  _twoFingerTimer = null;
                                },
                                onScaleEnd: (_) {
                                  _twoFingerTimer?.cancel();
                                  _twoFingerTimer = null;
                                },
                                child: textBox,
                              );

                              // 框视觉层（外扩，不参与尺寸；按钮/手柄独立可点）
                              // dragArea 在底层（含 textBox + 长按拖动 + 点框外收框）；
                              // 按钮/手柄在 dragArea 之上（Stack 上层优先命中，点击按钮不冒泡收框）
                              // 出框不跳：Stack 尺寸恒等于 textBox（Positioned 不参与尺寸），
                              // Align 对齐不因出框变化；按钮/手柄在 textBox 内（正坐标可命中）
                              final Widget boxLayer = Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  dragArea,
                                  // 虚线边框（覆盖 textBox 范围）
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
                                  // 设置按钮（左上角）
                                  Positioned(
                                    left: 2,
                                    top: 2,
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () {
                                        debugPrint('[SubtitleOverlay] 点击设置按钮');
                                        _showSrtSettingsPanel(context, videoState);
                                      },
                                      child: const Icon(
                                        Icons.tune,
                                        size: 18,
                                        color: Color(0xFFFFFFFF),
                                        shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                                      ),
                                    ),
                                  ),
                                  // 背景切换键（右上角）
                                  Positioned(
                                    right: 2,
                                    top: 2,
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () {
                                        debugPrint('[SubtitleOverlay] 点击背景切换按钮');
                                        setState(() {
                                          _subtitleBgEnabled = !_subtitleBgEnabled;
                                        });
                                      },
                                      child: const Icon(
                                        Icons.format_color_fill,
                                        size: 18,
                                        color: Color(0xFFFFFFFF),
                                        shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                                      ),
                                    ),
                                  ),
                                  // 右下角拉伸手柄（textBox 内右下，可命中）
                                ],
                              );

                              positionedContent = _boxVisible ? boxLayer : dragArea;
                            }





                            Widget content = Opacity(
                              opacity:
                                  videoState.subtitleOpacity.clamp(0.0, 1.0).toDouble(),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 16,
                                ),
                                child: Align(
                                  alignment: Alignment(
                                    _resolveHorizontalAlignment(videoState.subtitleAlignX),
                                    _resolveVerticalAlignment(videoState.subtitlePosition),
                                  ),
                                  child: Transform.translate(
                                                                      offset: Offset(
                                                                        videoState.subtitleMarginX,
                                                                        videoState.subtitleMarginY,
                                                                      ),
                                                                      child: positionedContent,
                                                                    ),
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

  // 长按字幕弹出 SRT 时轴延迟调整浮层（滑块 + 手动输入联动；独立于全局字幕延迟）
  // 双指长按弹出 SRT 设置面板：延迟滑块+手动输入联动（独立于全局）、字体选择、颜色调色板
  void _showSrtSettingsPanel(BuildContext context, VideoPlayerState videoState) {
    if (!videoState.currentExternalSubtitleIsSrt) return;
    // 字体列表只扫描一次（面板存续期间复用同一个 Future，避免 Consumer
    // 重建时反复触发 FutureBuilder 重新扫描）。
    final fontListFuture = _listSubtitleFontNames(videoState);
    // 历史缓存/远程下载的字体可能从未注册进引擎，打开面板时补注册，
    // 否则选中的 fontFamily 会静默回退默认字体。
    unawaited(videoState.ensureSelectedSubtitleFontsRegistered());
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xF0101010),
      barrierColor: Colors.black54,
      isScrollControlled: true,
      builder: (sheetContext) {
        final previewValue = ValueNotifier<double>(videoState.srtSubtitleDelaySeconds);
        final delayController = TextEditingController(
          text: _formatDelayInputText(videoState.srtSubtitleDelaySeconds),
        );
        void applyValue(double value) {
          videoState.setSrtSubtitleDelaySeconds(value);
          previewValue.value = value;
          delayController.text = _formatDelayInputText(value);
        }
        // 常用字幕颜色调色板
        const palette = <Color>[
          Colors.white, Colors.black, Colors.yellow, Colors.cyan,
          Color(0xFFFFD54F), Color(0xFFFF8A65), Color(0xFFAED581),
          Color(0xFF81D4FA), Color(0xFFF48FB1), Color(0xFFB39DDB),
        ];
        // 键盘弹出时把整块内容抬到键盘上方：底部内边距 = 键盘高度，
        // 否则输入框和滑块会被键盘完全遮挡（isScrollControlled 已开，
        // 配合 SingleChildScrollView 可滚动到被顶起的部分）。
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'SRT 字幕设置',
                  style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Text('时轴偏移（正值延后，负值提前）',
                    style: TextStyle(color: Colors.white60, fontSize: 12)),
                const SizedBox(height: 4),
                ValueListenableBuilder<double>(
                  valueListenable: previewValue,
                  builder: (context, value, _) {
                    return Slider(
                      value: value.clamp(
                        videoState.subtitleDelaySliderMinSeconds,
                        videoState.subtitleDelaySliderMaxSeconds,
                      ),
                      min: videoState.subtitleDelaySliderMinSeconds,
                      max: videoState.subtitleDelaySliderMaxSeconds,
                      divisions: videoState.subtitleDelaySliderDivisions,
                      label: _formatDelayDisplayText(value),
                      onChanged: applyValue,
                    );
                  },
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: delayController,
                        keyboardType: const TextInputType.numberWithOptions(
                            signed: true, decimal: true),
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: '例如 -12.5 或 8',
                          hintStyle: TextStyle(color: Colors.white38, fontSize: 14),
                          labelText: '秒',
                          labelStyle: TextStyle(color: Colors.white60, fontSize: 12),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.white24),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.amber),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                        ),
                        onChanged: (text) {
                          final parsed = double.tryParse(text.trim());
                          if (parsed != null) applyValue(parsed);
                        },
                        onSubmitted: (text) {
                          final parsed = double.tryParse(text.trim());
                          if (parsed != null) applyValue(parsed);
                          FocusScope.of(sheetContext).unfocus();
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton(
                      onPressed: () => FocusScope.of(sheetContext).unfocus(),
                      icon: const Icon(Icons.check, color: Colors.amber),
                      tooltip: '完成',
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text('字号', style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 4),
                // Consumer 而非一次性 ValueNotifier：之前每次重建都新建
                // ValueNotifier(srtSubtitleScale)，拖动时 thumb 永不移动，
                // 直到键盘收起触发整页重建才“跳”到当前值。
                Consumer<VideoPlayerState>(
                  builder: (context, vs, _) {
                    final scale = vs.srtSubtitleScale;
                    return Slider(
                      value: scale.clamp(0.5, 3.0),
                      min: 0.5,
                      max: 3.0,
                      divisions: 50,
                      label: '${scale.toStringAsFixed(2)}x',
                      onChanged: (value) => videoState.setSrtSubtitleScale(value),
                    );
                  },
                ),
                const SizedBox(height: 14),
                Text('字体（可多选）', style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 6),
                // Consumer 包一层：点选字体后立即反映选中态（之前要关掉面板
                // 重开才能看到多选/取消的变化）。
                Consumer<VideoPlayerState>(
                  builder: (context, vs, _) {
                    return FutureBuilder<List<String>>(
                      future: fontListFuture,
                      builder: (context, snapshot) {
                        final fonts = snapshot.data ?? <String>[];
                        final current = vs.subtitleFontName;
                        // 当前字体按逗号拆分（多选字体为逗号分隔 fallback 列表）
                        final selected = current
                            .split(',')
                            .map((e) => e.trim())
                            .where((e) => e.isNotEmpty)
                            .toSet();
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final f in fonts)
                              FilterChip(
                                label: Text(f, style: const TextStyle(fontSize: 12)),
                                selected: selected.contains(f),
                                onSelected: (sel) {
                                  final next = sel
                                      ? [...selected, f].join(',')
                                      : selected.where((e) => e != f).join(',');
                                  videoState.setSubtitleFontName(next);
                                },
                              ),
                          ],
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 14),
                Text('文字颜色', style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 8),
                Consumer<VideoPlayerState>(
                  builder: (context, vs, _) {
                    return Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final color in palette)
                          GestureDetector(
                            onTap: () => videoState.setSubtitleColor(color),
                            child: Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: vs.subtitleColor.toARGB32() == color.toARGB32()
                                      ? Colors.amber
                                      : Colors.white24,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          ),
        );
      },
    );
  }

  /// 字幕轴同步诊断：同一条字幕只记一次，且全局每秒最多一条，
  /// 输出 [SubtitleSync] 供日志终端比对内核间的时间轴来源差异。
  void _logSubtitleSyncOnce({
    required VideoPlayerState videoState,
    required String cueKey,
    required int subtitleTimeMs,
  }) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (cueKey == _lastLoggedCueKey ||
        nowMs - _lastSyncLogAtMs < _syncLogMinIntervalMs) {
      return;
    }
    _lastLoggedCueKey = cueKey;
    _lastSyncLogAtMs = nowMs;
    debugPrint(
      '[SubtitleSync] kernel=${videoState.player.getPlayerKernelName()} '
      'smooth=${widget.currentPositionMs.round()}ms '
      'raw=${videoState.player.position}ms '
      'lookup=${subtitleTimeMs}ms '
      'srtDelay=${videoState.srtSubtitleDelaySeconds.toStringAsFixed(1)}s '
      'cue=${cueKey.length > 24 ? '${cueKey.substring(0, 24)}...' : cueKey}',
    );
  }

  // 与字幕设置菜单共用同一字体列表（含字体库 subtitle_fonts + 本地 fonts）
  Future<List<String>> _listSubtitleFontNames(VideoPlayerState videoState) {
    return videoState.listSubtitleFonts();
  }


  String _formatDelayInputText(double value) {
    if (value.abs() < 0.0001) return '0';
    var text = value.toStringAsFixed(3);
    if (text.contains('.')) {
      text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return text;
  }

  String _formatDelayDisplayText(double value) {
    final prefix = value > 0 ? '+' : '';
    return '$prefix${value.toStringAsFixed(1)}s';
  }

  // 右下角拉伸手柄：Listener 原生事件，不与长按抢；放在拖动 GestureDetector 外，确保可命中

  // 右下角拉伸手柄：Listener 原生事件，不与长按抢；放在拖动 GestureDetector 外，确保可命中

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
