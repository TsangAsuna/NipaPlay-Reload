part of video_player_state;

/// 位图字幕 codec 黑名单（mpv track-list codec 值）：这些轨没有文本流，
/// sub-text 恒为空，整块叠层模式对它们必然黑屏，必须保持内核渲染。
const Set<String> _bitmapSubtitleCodecs = {
  'hdmv_pgs_subtitle',
  'dvd_subtitle',
  'dvb_subtitle',
  'dvb_teletext',
  'arib_caption',
};

/// 整块叠层的内核回退阈值：应用 sub-visibility=no 后超过该时长仍一个字
/// 都没收到，就回退内核渲染（可逆——轮询拿到文本后自动切回叠层）。
const Duration _embeddedOverlayFallbackAfter = Duration(seconds: 25);

extension VideoPlayerStateSubtitles on VideoPlayerState {
  void _attachPluginDanmakuFilter() {
    _detachPluginDanmakuFilter();

    final context = _context;
    if (context == null || !context.mounted) {
      return;
    }

    PluginService? pluginService;
    try {
      pluginService = context.read<PluginService>();
    } catch (_) {
      pluginService = null;
    }
    if (pluginService == null) {
      return;
    }

    _pluginService = pluginService;
    _pluginServiceListener = () {
      _syncPluginDanmakuBlockWords();
    };
    pluginService.addListener(_pluginServiceListener!);
    _syncPluginDanmakuBlockWords();

    // 注册播放器状态引用，供插件桥接调用
    PluginService.setPlayerState(this);
  }

  void _detachPluginDanmakuFilter() {
    final listener = _pluginServiceListener;
    final service = _pluginService;
    if (listener != null && service != null) {
      service.removeListener(listener);
    }
    _pluginServiceListener = null;
    _pluginService = null;
    _pluginDanmakuBlockWords = [];

    // 清除播放器状态引用
    PluginService.clearPlayerState();
  }

  void _syncPluginDanmakuBlockWords() {
    final service = _pluginService;
    if (service == null) return;

    final words = service.activeDanmakuBlockWords;
    if (listEquals(words, _pluginDanmakuBlockWords)) {
      return;
    }
    _pluginDanmakuBlockWords = words;
    _updateMergedDanmakuList();
  }

  // 更新指定的字幕轨道信息
  void _updateSubtitleTracksInfo(int trackIndex) {
    if (player.mediaInfo.subtitle == null ||
        trackIndex >= player.mediaInfo.subtitle!.length) {
      return;
    }

    final track = player.mediaInfo.subtitle![trackIndex];
    // 尝试从track中提取title和language
    String title = '轨道 $trackIndex';
    String language = '未知';

    final fullString = track.toString();
    if (fullString.contains('metadata: {')) {
      final metadataStart =
          fullString.indexOf('metadata: {') + 'metadata: {'.length;
      final metadataEnd = fullString.indexOf('}', metadataStart);

      if (metadataEnd > metadataStart) {
        final metadataStr = fullString.substring(metadataStart, metadataEnd);

        // 提取title
        final titleMatch = RegExp(r'title: ([^,}]+)').firstMatch(metadataStr);
        if (titleMatch != null) {
          title = titleMatch.group(1)?.trim() ?? title;
        }

        // 提取language
        final languageMatch =
            RegExp(r'language: ([^,}]+)').firstMatch(metadataStr);
        if (languageMatch != null) {
          language = languageMatch.group(1)?.trim() ?? language;
          // 获取映射后的语言名称
          language = getSubtitleLanguageName(language);
        }
      }
    }

    // 更新VideoPlayerState的字幕轨道信息
    _subtitleManager.updateSubtitleTrackInfo('embedded_subtitle_$trackIndex', {
      'index': trackIndex,
      'title': title,
      'language': language,
      'isActive': player.activeSubtitleTracks.contains(trackIndex)
    });

    // 清除外部字幕信息的激活状态
    if (_subtitleManager.currentExternalSubtitlePath == null &&
        player.activeSubtitleTracks.contains(trackIndex) &&
        _subtitleManager.subtitleTrackInfo.containsKey('external_subtitle')) {
      _subtitleManager
          .updateSubtitleTrackInfo('external_subtitle', {'isActive': false});
    }
  }

  // 更新所有字幕轨道信息
  void _updateAllSubtitleTracksInfo() {
    if (player.mediaInfo.subtitle == null) {
      return;
    }

    // 清除之前的内嵌字幕轨道信息
    for (final key in List.from(_subtitleManager.subtitleTrackInfo.keys)) {
      if (key.startsWith('embedded_subtitle_')) {
        _subtitleManager.subtitleTrackInfo.remove(key);
      }
    }

    // 更新所有内嵌字幕轨道信息
    for (var i = 0; i < player.mediaInfo.subtitle!.length; i++) {
      _updateSubtitleTracksInfo(i);
    }

    // 在更新完成后检查当前激活的字幕轨道并确保相应的信息被更新
    if (player.activeSubtitleTracks.isNotEmpty &&
        _subtitleManager.currentExternalSubtitlePath == null) {
      final activeIndex = player.activeSubtitleTracks.first;
      if (activeIndex >= 0 && activeIndex < player.mediaInfo.subtitle!.length) {
        // 激活的是内嵌字幕轨道
        _subtitleManager.updateSubtitleTrackInfo('embedded_subtitle', {
          'index': activeIndex,
          'title': player.mediaInfo.subtitle![activeIndex].toString(),
          'isActive': true,
        });

        // 通知字幕轨道变化
        _subtitleManager.onSubtitleTrackChanged();
      }
    }

    _notifyListeners();
  }

  // 设置当前外部字幕路径
  void setCurrentExternalSubtitlePath(String path) {
    _subtitleManager.setCurrentExternalSubtitlePath(path);
    //debugPrint('设置当前外部字幕路径: $path');
  }

  // 设置外部字幕并更新路径
  void setExternalSubtitle(String path, {bool isManualSetting = false}) {
    _subtitleManager.setExternalSubtitle(path,
        isManualSetting: isManualSetting);
    // Activation changes which kernel track owns the sid; the whole-block
    // mode must step aside for a kernel-rendered external ASS (and resume
    // for embedded tracks), so re-sync sub-visibility.
    applyEmbeddedSubtitleOverlayKernelState();
    _notifyListeners();
  }

  // 选内嵌字幕轨（>= 0）或关闭字幕（< 0），同时摘掉外挂字幕
  void selectEmbeddedSubtitleTrack(int trackIndex) {
    _subtitleManager.selectEmbeddedSubtitleTrack(trackIndex);
    _notifyListeners();
  }

  // 强制设置外部字幕（手动操作）
  void forceSetExternalSubtitle(String path) {
    _subtitleManager.forceSetExternalSubtitle(path);
    applyEmbeddedSubtitleOverlayKernelState();
    _notifyListeners();
  }

  // 桥接方法：预加载字幕文件
  Future<void> preloadSubtitleFile(String path) async {
    await _subtitleManager.preloadSubtitleFile(path);
  }

  // 桥接方法：叠加挂载外部字幕到堆栈（多挂，可带显示名）
  Future<void> addExternalSubtitleToStack(String path,
      {String? displayName}) async {
    await _subtitleManager.addExternalSubtitleToStack(path,
        displayName: displayName);
    _notifyListeners();
  }

  // 桥接方法：取消挂载外部字幕（从叠层/内核移除）
  Future<void> removeExternalSubtitle(String path) async {
    await _subtitleManager.removeExternalSubtitleFromStack(path);
    _notifyListeners();
  }

  // 桥接方法：获取当前活跃的外部字幕文件路径
  String? getActiveExternalSubtitlePath() {
    return _subtitleManager.getActiveExternalSubtitlePath();
  }

  // 桥接方法：获取当前显示的字幕文本
  String getCurrentSubtitleText() {
    return _subtitleManager.getCurrentSubtitleText();
  }

  // ---- 多字幕分块渲染桥接：每条外挂字幕独立的时轴延迟/位置/边距 ----

  /// 全部活跃的外挂字幕路径（有序，多挂时逐条叠加渲染）
  List<String> get activeExternalSubtitlePaths =>
      _subtitleManager.getAllActiveExternalSubtitlePaths();

  /// 查询单条字幕在指定时间点的文本
  String pathSubtitleTextAt(String path, int positionMs) =>
      _subtitleManager.pathSubtitleTextAt(path, positionMs);

  /// 叠层里这条外挂字幕的总偏移（毫秒）：SRT/VTT 含共用的 SRT 偏移
  int overlaySubtitleDelayMs(String path) =>
      _subtitleManager.overlayDelayMs(path);

  /// 叠层此刻给出的这条外挂字幕的那一行（已按偏移）
  String overlaySubtitleTextAt(String path, int playbackMs) =>
      _subtitleManager.overlayTextAt(path, playbackMs);

  /// 某条字幕的显示名（无登记时回退文件名）
  String externalSubtitleDisplayName(String path) =>
      _subtitleManager.displayNameForPath(path);

  /// 某条字幕的时轴延迟（秒；正值延后，负值提前）
  double pathSubtitleDelaySeconds(String path) =>
      _subtitleManager.pathDelaySeconds(path);

  void setPathSubtitleDelaySeconds(String path, double seconds) {
    _subtitleManager.setPathDelaySeconds(path, seconds);
    _notifyListeners();
  }

  /// 某条字幕的垂直位置（0=屏幕顶 100=屏幕底）
  double pathSubtitlePosition(String path) =>
      _subtitleManager.pathPosition(path);

  /// 该外挂字幕是否走 App 叠层渲染（false = 内核轨，libmpv ASS）
  bool externalSubtitleRenderedInApp(String path) =>
      _subtitleManager.externalSubtitleRenderedInApp(path);

  void setPathSubtitlePosition(String path, double position) {
    _subtitleManager.setPathPosition(path, position);
    _notifyListeners();
  }

  /// 某条字幕的水平边距（逻辑像素）
  double pathSubtitleMarginX(String path) =>
      _subtitleManager.pathMarginX(path);

  void setPathSubtitleMarginX(String path, double marginX) {
    _subtitleManager.setPathMarginX(path, marginX);
    _notifyListeners();
  }

  // 桥接方法：判断当前外挂字幕是否使用应用内叠层渲染
  bool shouldRenderCurrentExternalSubtitleInApp() {
    return _subtitleManager.shouldRenderCurrentExternalSubtitleInApp();
  }

  // 桥接方法：获取指定时间点的外挂字幕文本
  String getCurrentExternalSubtitleTextAt(int positionMs) {
    return _subtitleManager.getCurrentExternalSubtitleTextAt(positionMs);
  }

  // 桥接方法：当字幕轨道改变时调用
  void onSubtitleTrackChanged() {
    _subtitleManager.onSubtitleTrackChanged();
  }

  // ---- Whole-block embedded subtitle mode (bilingual, non-overlapping) ----

  /// Whether whole-block mode is enabled. With it on, the kernel only
  /// decodes (sub-visibility=no) while the app renders the whole block from
  /// sub-text polling: the position slider moves the entire block so the
  /// authored bilingual line gap never collapses, and the horizontal margin
  /// applies in screen pixels regardless of the script's PlayRes.
  ///
  /// Exception: while a kernel-rendered external ASS/SSA is active the mode
  /// steps aside (see [isKernelRenderedExternalAssActive]) so libass keeps
  /// rendering that track with its script styles.
  bool get embeddedSubtitleOverlayMode => _embeddedSubtitleOverlayMode;

  /// Whether the currently active external subtitle is a kernel-track
  /// ASS/SSA. Whole-block mode only serves embedded tracks — an external
  /// ASS is rendered by libass with script-dominant styling; flattening it
  /// through sub-visibility=no + a sub-text text block would strip \pos
  /// positioning and colors.
  bool get isKernelRenderedExternalAssActive =>
      _subtitleManager.isKernelRenderedExternalAssActive();

  Future<void> setEmbeddedSubtitleOverlayMode(bool enabled) async {
    if (_embeddedSubtitleOverlayMode == enabled) return;
    _embeddedSubtitleOverlayMode = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_embeddedSubtitleOverlayModeKey, enabled);
    // 用户显式切换模式：清掉回退态，重新武装叠层（否则回退后再次开启
    // 会因为 guard 不生效，表现为"开关无效"）。
    _embeddedOverlayFallbackActive = false;
    _embeddedOverlayEverGotText = false;
    _embeddedOverlayAppliedNoMs = 0;
    applyEmbeddedSubtitleOverlayKernelState();
    _notifyListeners();
  }

  /// Whole-block text for the current position (kernel sub-text polling;
  /// empty = no subtitle right now).
  String get embeddedSubtitleOverlayText => _embeddedSubtitleOverlayText;

  /// The text actually rendered: bilingual line order auto-correction.
  /// The kernel orders sub-text lines by event order, which may put the
  /// Japanese line first. Lines containing kana are treated as the original
  /// (bottom), pure-Han lines as the translation (top); when there is no
  /// kana evidence the kernel order is kept.
  String get embeddedSubtitleOverlayDisplayText {
    final text = _embeddedSubtitleOverlayText;
    if (!text.contains('\n')) return text;
    final lines = text.split('\n');
    bool hasKana(String s) {
      for (final r in s.runes) {
        if ((r >= 0x3041 && r <= 0x309F) || // Hiragana
            (r >= 0x30A0 && r <= 0x30FF) || // Katakana
            (r >= 0x31F0 && r <= 0x31FF) || // Katakana phonetic extensions
            (r >= 0xFF66 && r <= 0xFF9D)) {
          // Halfwidth katakana
          return true;
        }
      }
      return false;
    }

    final kanaCount = lines.where(hasKana).length;
    if (kanaCount == 0 || kanaCount == lines.length) return text;
    final japanese = lines.where(hasKana).toList();
    final chinese = lines.where((l) => !hasKana(l)).toList();
    return [...chinese, ...japanese].join('\n');
  }

  /// Sync the kernel render switch with the current mode. Idempotent; call
  /// after mode toggles, video open, kernel hot-swap, and external-subtitle
  /// activation changes. Media Kit + mode on + no kernel-rendered external
  /// ASS -> sub-visibility=no; otherwise yes (and residue text is cleared).
  ///
  /// 两类自愈例外（不写 'no'，保持内核渲染）：
  /// 1. 当前选中的是位图字幕轨（PGS/VobSub 等）——sub-text 恒为空，叠层
  ///    必然黑屏；
  /// 2. 回退生效期间（[_embeddedOverlayFallbackActive]）——等文本恢复后
  ///    由轮询自动切回叠层。
  void applyEmbeddedSubtitleOverlayKernelState() {
    if (kIsWeb || _isDisposed) return;
    try {
      final kernel = player.getPlayerKernelName();
      final externalAss = isKernelRenderedExternalAssActive;
      final bitmap = _isBitmapSubtitleTrackActive();
      final overlayActive = kernel == 'Media Kit' &&
          _embeddedSubtitleOverlayMode &&
          !externalAss &&
          !_embeddedOverlayFallbackActive &&
          !bitmap;
      if (overlayActive) {
        player.setProperty('sub-visibility', 'no');
        _embeddedOverlayEverGotText = false;
        // 首次应用 'no' 的时间戳决定回退时刻；用户反复重选轨道不得推迟
        // 回退——否则"一直勾选/切换轨道"会让 25s 回退永远不触发，黑屏无解。
        if (_embeddedOverlayAppliedNoMs <= 0) {
          _embeddedOverlayAppliedNoMs = DateTime.now().millisecondsSinceEpoch;
        }
      } else {
        _embeddedOverlayAppliedNoMs = 0;
        player.setProperty('sub-visibility', 'yes');
        if (_embeddedSubtitleOverlayText.isNotEmpty) {
          _embeddedSubtitleOverlayText = '';
          _notifyListeners();
        }
      }
      // 诊断（release 可见）：每次内核渲染开关的决策都留痕，用于定位
      // "勾选却不显示"时到底是模式/位图/外挂 ASS/回退哪个分支。
      debugPrint(
        '[整块叠层] 状态: kernel=$kernel mode=$_embeddedSubtitleOverlayMode '
        'externalAss=$externalAss bitmap=$bitmap '
        'fallback=$_embeddedOverlayFallbackActive -> '
        'sub-visibility=${overlayActive ? 'no' : 'yes'}',
      );
    } catch (e) {
      debugPrint('VideoPlayerState: sync whole-block kernel state failed: $e');
    } finally {
      _syncEmbeddedOverlayPausedTimer();
    }
  }

  /// 当前选中的内嵌字幕轨是否为位图轨（无文本流）。
  /// 适配器只有在 mpv 的轨道事件回来后才更新 activeSubtitleTracks，
  /// 而字幕菜单是"先写勾选、立刻通知"，所以刚点下的那一条必须从
  /// SubtitleManager 的最近选择里补上，否则文本轨→位图轨会漏判成
  /// 可叠层，写 sub-visibility=no 后位图字幕整块黑掉。
  bool _isBitmapSubtitleTrackActive() {
    try {
      final subtitles = player.mediaInfo.subtitle;
      if (subtitles == null || subtitles.isEmpty) return false;
      // 只判定"当前实际生效的那一条"：用户在菜单里的选择优先（适配器
      // 回写 activeSubtitleTracks 有延迟），没有用户选择时用已生效轨。
      // 不能把两者并集——列表里只要存在一条位图轨就会把文本轨误判成
      // 位图轨，叠层模式被静默关掉。
      final active = player.activeSubtitleTracks;
      final last = subtitleManager.lastSelectedEmbeddedTrackIndex;
      final index = (last >= 0 && last < subtitles.length)
          ? last
          : (active.isNotEmpty ? active.first : -1);
      if (index < 0 || index >= subtitles.length) return false;
      final codec = (subtitles[index].metadata['codec'] ?? '')
          .toString()
          .toLowerCase();
      if (codec.isEmpty) return false;
      return _bitmapSubtitleCodecs.any((bitmap) => codec.startsWith(bitmap));
    } catch (_) {}
    return false;
  }

  /// 回退判定（惰性）：应用 sub-visibility=no 后超过
  /// [_embeddedOverlayFallbackAfter] 仍零文本就回退内核渲染（可逆——
  /// 轮询拿到文本后由 [_pollEmbeddedSubtitleOverlayText] 自动切回叠层）。
  /// 由轮询心跳调用；不持有长活 Timer，避免 flutter_test 的
  /// !timersPending 不变量失败。
  void _maybeApplyEmbeddedOverlayKernelFallback() {
    if (_isDisposed ||
        kIsWeb ||
        !_embeddedSubtitleOverlayMode ||
        _embeddedOverlayFallbackActive ||
        _embeddedOverlayEverGotText ||
        isKernelRenderedExternalAssActive ||
        _embeddedOverlayAppliedNoMs <= 0) {
      return;
    }
    final elapsed = DateTime.now().millisecondsSinceEpoch -
        _embeddedOverlayAppliedNoMs;
    if (elapsed < _embeddedOverlayFallbackAfter.inMilliseconds) {
      return;
    }
    _embeddedOverlayFallbackActive = true;
    _embeddedSubtitleOverlayText = '';
    try {
      player.setProperty('sub-visibility', 'yes');
    } catch (_) {}
    debugPrint(
      '[VideoPlayerState] 整块叠层 ${_embeddedOverlayFallbackAfter.inSeconds}'
      's 内未收到任何字幕文本，回退内核渲染（sub-visibility=yes）',
    );
    _notifyListeners();
  }

  /// 诊断（release 可见，10s 节流）：Media Kit 播放期采样"真实"内核字幕
  /// 状态——sid / sub-visibility / sub-text 长度 / 缩放与位置 / 勾选状态 /
  /// 叠层模式。用户日志里出现这一行，就能直接定位"勾选却不显示"卡在
  /// 哪一层（mpv 没选上轨 / 渲染被关 / 文本为空 / 位置被推到画面外）。
  void debugSampleSubtitleKernelState() {
    if (kIsWeb || _isDisposed) return;
    if (player.getPlayerKernelName() != 'Media Kit') return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastSubtitleKernelSampleMs < 10000) return;
    _lastSubtitleKernelSampleMs = nowMs;
    unawaited(() async {
      try {
        // 逐个读取，null 保留下来单独标注——`?? ''` 会把"读取失败"和
        // 真实空值混成同一个样子，日志判读时会得出相反结论。
        const names = <String>[
          'sid',
          'sub-visibility',
          'sub-text',
          'sub-scale',
          'sub-pos',
          'sub-margin-y',
          // sub-start/sub-end 非空 = 字幕包已解码到当前时刻；恒空 =
          // 解复用/投递就断了（与 libass 无关）。sub-delay 离谱 = 整集
          // 字幕被平移出时间轴。drop-count 暴涨 = 渲染跟不上（跳帧）。
          'sub-delay',
          'sub-start',
          'sub-end',
          'sub-ass-override',
          'sub-opacity',
          'sub-font',
          'sub-fonts-dir',
          'embeddedfonts',
          'speed',
          'frame-drop-count',
          'mistimed-frame-count',
        ];
        final values = <String, String?>{};
        for (final name in names) {
          values[name] = await player.getLiveProperty(name);
        }
        if (_isDisposed) return;
        final nulls = <String>[
          for (final entry in values.entries)
            if (entry.value == null) entry.key,
        ];
        final text = values['sub-text'] ?? '';
        debugPrint(
          '[字幕采样] sid=${values['sid']} '
          'vis=${values['sub-visibility']} textLen=${text.length} '
          'subStart="${values['sub-start']}" '
          'subEnd="${values['sub-end']}" delay=${values['sub-delay']} '
          'scale=${values['sub-scale']} pos=${values['sub-pos']} '
          'marginY=${values['sub-margin-y']} '
          'override=${values['sub-ass-override']} '
          'opacity=${values['sub-opacity']} '
          'font="${values['sub-font']}" '
          'fontsDir="${values['sub-fonts-dir']}" '
          'embeddedFonts=${values['embeddedfonts']} '
          'speed=${values['speed']} dropped=${values['frame-drop-count']} '
          'mistimed=${values['mistimed-frame-count']} '
          'tracks=${player.activeSubtitleTracks} '
          'mode=$_embeddedSubtitleOverlayMode '
          'fallback=$_embeddedOverlayFallbackActive '
          'nulls=$nulls',
        );
      } catch (_) {}
    }());
  }

  /// 一次性自愈：开始播放 2.5s 后 Media Kit 内嵌轨仍然一个字的文本都没有，
  /// 就把当前 sid 重写一次，强制 mpv 从当前位置重载字幕流。
  /// 覆盖"选轨发生在解复用器就绪之前：sid 写进去了、字幕包却从未投递"的
  /// 竞态（mpv 只在 sub_reload 时补发历史字幕包）。
  /// 用 ticker 驱动而不是 Timer，避免测试里的 timersPending 不变量。
  /// [positionMs] 用播放进度而不是墙钟：起播缓冲 2.5s 时解复用器可能还
  /// 没就绪，那时重选只会白耗掉这一次自愈机会。
  void maybeRearmSilentSubtitle({int? positionMs}) {
    if (kIsWeb || _isDisposed || _silentSubtitleRearmDone) return;
    if (_status != PlayerStatus.playing) return;
    if (player.getPlayerKernelName() != 'Media Kit') return;
    final progressMs = positionMs ?? player.position;
    // 起播/恢复播放后给解复用器与字幕解码器一个落地的窗口：进度没动
    // 或者刚起来不到 2.5s 都不判定，避免把唯一一次自愈耗在准备阶段。
    final startMs = _lastPlaybackStartMs;
    if (startMs <= 0) return;
    if (DateTime.now().millisecondsSinceEpoch - startMs < 2500) return;
    if (progressMs < 2500) return;
    // 超过 6s 还没触发说明这条路径不需要自愈（正常出字/无字幕），
    // 直接收旗，别再每帧去做属性读取。
    if (progressMs > 6000) {
      _silentSubtitleRearmDone = true;
      return;
    }
    if (player.activeSubtitleTracks.isEmpty) return;
    if (activeExternalSubtitlePaths.isNotEmpty) return;
    unawaited(() async {
      try {
        final text = await player.getLiveProperty('sub-text') ?? '';
        if (text.isNotEmpty) {
          // 有字说明字幕链路正常，这一集不需要自愈（否则健康轨道也会在
          // 第一段对白间隙被误判成"没有字幕"触发一次强制重选）。
          _silentSubtitleRearmDone = true;
          return;
        }
        var sid = await player.getLiveProperty('sid') ?? '';
        if (sid.isEmpty || sid == 'no' || sid == 'auto') {
          // mpv 还没把轨道 id 认下来——这时按勾选轨自己解析出目标 id，
          // 否则这一次自愈会被白白跳过（而这正是要修的竞态）。
          final resolved = _resolveActiveEmbeddedSubtitleMpvId();
          final subStart = await player.getLiveProperty('sub-start') ?? '';
          if (resolved == null) {
            debugPrint(
              '[字幕自愈] 跳过：mpv sid=$sid，勾选轨也解析不出 id'
              '（subStart="$subStart"）',
            );
            return;
          }
          sid = resolved;
        }
        if (_silentSubtitleRearmDone || _isDisposed) return;
        _silentSubtitleRearmDone = true;
        debugPrint(
          '[字幕自愈] ${(progressMs / 1000).toStringAsFixed(1)}s 处仍 0 文本，'
          '强制重选 sid=$sid（等价手动取消再勾选）',
        );
        // 同值 sid 写入通常被 mpv 短路成 no-op，这里先 no 再 id 强制重载
        // 字幕解码器；与用户在 UI 里"取消勾选再打勾"等价，但自动执行一次。
        player.setProperty('sid', 'no');
        player.setProperty('sid', sid);
        // 重选可能把 sub-visibility 打回默认，按当前模式重新同步一次。
        // 不要回写 activeSubtitleTracks：适配器的 setter 会再发一次选轨
        // 请求，可能把刚写进去的 sid 又覆盖掉。
        applyEmbeddedSubtitleOverlayKernelState();
      } catch (_) {}
    }());
  }

  /// 从当前勾选的内嵌轨解析 mpv 的 sid（metadata['id']）。适配器把 mpv
  /// 的轨道 id 放在 metadata 里，这里不依赖 mpv 的实时 sid。
  /// 只认 activeSubtitleTracks：lastSelected 可能是关闭字幕前的残留，
  /// 盲目回退会把 sid 重选到另一条轨上。
  String? _resolveActiveEmbeddedSubtitleMpvId() {
    try {
      final subtitles = player.mediaInfo.subtitle;
      if (subtitles == null || subtitles.isEmpty) return null;
      for (final index in player.activeSubtitleTracks) {
        if (index < 0 || index >= subtitles.length) continue;
        final id = (subtitles[index].metadata['id'] ?? '').toString();
        if (id.isNotEmpty && id != 'no' && id != 'auto') return id;
      }
    } catch (_) {}
    return null;
  }

  /// 暂停态刷新计时器汇聚点：pause() 会停掉 UI ticker（整块叠层的暂停
  /// 轮询原本依附 ticker，是死代码），这里用独立计时器补上——暂停时每
  /// 800ms 刷新一次当前行（样式拖动、打开即暂停的场景不再冻结）。
  /// 计时器回调自带状态检查，恢复播放后自动退出。
  void _syncEmbeddedOverlayPausedTimer() {
    final shouldRun = _embeddedSubtitleOverlayMode &&
        !_embeddedOverlayFallbackActive &&
        !kIsWeb &&
        !_isDisposed &&
        hasVideo &&
        // 整块叠层只对 Media Kit 生效；Erika/MDK 暂停时没必要每 800ms
        // 去读一次 sub-text（那边拿不到值，白耗通道）。
        player.getPlayerKernelName() == 'Media Kit' &&
        _status == PlayerStatus.paused;
    if (!shouldRun) {
      _pausedOverlayPollTimer?.cancel();
      _pausedOverlayPollTimer = null;
      return;
    }
    if (_pausedOverlayPollTimer == null) {
      unawaited(_pollEmbeddedSubtitleOverlayText());
    }
    _pausedOverlayPollTimer ??= Timer.periodic(
      const Duration(milliseconds: 800),
      (_) {
        final stillPaused = _embeddedSubtitleOverlayMode &&
            !_embeddedOverlayFallbackActive &&
            !_isDisposed &&
            hasVideo &&
            _status == PlayerStatus.paused;
        if (!stillPaused) {
          _pausedOverlayPollTimer?.cancel();
          _pausedOverlayPollTimer = null;
          return;
        }
        unawaited(_pollEmbeddedSubtitleOverlayText());
      },
    );
  }

  /// 新视频打开 / 换内核：清空回退与已出字状态，由随后的
  /// applyEmbeddedSubtitleOverlayKernelState 重新武装。
  void _resetEmbeddedOverlayPipelineState() {
    _embeddedOverlayEverGotText = false;
    _embeddedOverlayFallbackActive = false;
    _embeddedOverlayAppliedNoMs = 0;
    _silentSubtitleRearmDone = false;
  }

  /// Throttled poll entry from the position ticker (~8Hz, notifies only on
  /// text change).
  void pollEmbeddedSubtitleOverlayText() {
    if (!_embeddedSubtitleOverlayMode || kIsWeb || _isDisposed) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastEmbeddedSubTextPollMs < 120) return;
    _lastEmbeddedSubTextPollMs = nowMs;
    unawaited(_pollEmbeddedSubtitleOverlayText());
  }

  /// Reduced-frequency poll while paused (800ms): keeps the text fresh when
  /// the user drags style sliders on a paused frame — otherwise the stale
  /// line can be pushed off-frame by a kernel style recompute and the user
  /// perceives "subtitle vanished until the next seek".
  void pollEmbeddedSubtitleOverlayTextPaused() {
    if (!_embeddedSubtitleOverlayMode || kIsWeb || _isDisposed) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastEmbeddedSubTextPollMs < 800) return;
    _lastEmbeddedSubTextPollMs = nowMs;
    unawaited(_pollEmbeddedSubtitleOverlayText());
  }

  Future<void> _pollEmbeddedSubtitleOverlayText() async {
    try {
      // While a kernel-rendered external ASS is active the whole block must
      // not render (libass owns the styling); clear any residue collected
      // before the switch so it never overlays the libass render.
      if (isKernelRenderedExternalAssActive) {
        if (_embeddedSubtitleOverlayText.isNotEmpty) {
          _embeddedSubtitleOverlayText = '';
          _notifyListeners();
        }
        return;
      }
      final text = await player.getLiveProperty('sub-text') ?? '';
      if (_isDisposed) return;
      final trimmed = text.trim();
      if (trimmed.isNotEmpty) {
        if (!_embeddedOverlayEverGotText) {
          _embeddedOverlayEverGotText = true;
          _embeddedOverlayAppliedNoMs = 0;
        }
        if (_embeddedOverlayFallbackActive) {
          // 回退期间文本恢复：切回整块叠层（先清残留文本再关内核渲染，
          // 避免内核与叠层双渲染）。
          _embeddedOverlayFallbackActive = false;
          _embeddedSubtitleOverlayText = '';
          try {
            player.setProperty('sub-visibility', 'no');
          } catch (_) {}
          _notifyListeners();
          return;
        }
      } else {
        // 文本迟迟不出字（位图轨/轮询失效/mpv 侧丢轨）：惰性回退内核渲染。
        _maybeApplyEmbeddedOverlayKernelFallback();
        // 诊断（release 可见，5s 节流）：勾选了轨却黑屏时，这条日志能区分
        // "mpv 侧没选上轨（sid=no）"、"sub-visibility 被关（应为 no）"与
        // "sub-text 正常为空（行间隙/位图轨）"。
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - _lastEmbeddedOverlayDebugLogMs > 5000) {
          _lastEmbeddedOverlayDebugLogMs = nowMs;
          final sid = await player.getLiveProperty('sid') ?? '';
          final visibility =
              await player.getLiveProperty('sub-visibility') ?? '';
          debugPrint(
            '[整块叠层] sub-text 为空: sid=$sid sub-visibility=$visibility '
            'tracks=${player.activeSubtitleTracks} '
            'fallback=$_embeddedOverlayFallbackActive '
            'appliedNoMs=$_embeddedOverlayAppliedNoMs',
          );
        }
      }
      if (trimmed == _embeddedSubtitleOverlayText) return;
      _embeddedSubtitleOverlayText = trimmed;
      _notifyListeners();
    } catch (_) {}
  }

  /// Test-only: inject the whole-block text directly (bypasses the real
  /// clock throttle so widget tests on FakeAsync can drive it with pump).
  @visibleForTesting
  void debugSetEmbeddedSubtitleOverlayText(String text) {
    _embeddedSubtitleOverlayText = text;
    _notifyListeners();
  }

  // 桥接方法：获取缓存的字幕内容
  List<dynamic>? getCachedSubtitle(String path) {
    return _subtitleManager.getCachedSubtitle(path);
  }

  // 桥接方法：获取弹幕/字幕轨道信息
  Map<String, Map<String, dynamic>> get danmakuTrackInfo =>
      _subtitleManager.subtitleTrackInfo;

  // 桥接方法：更新弹幕/字幕轨道信息
  void updateDanmakuTrackInfo(String key, Map<String, dynamic> info) {
    _subtitleManager.updateSubtitleTrackInfo(key, info);
  }

  // 桥接方法：清除弹幕/字幕轨道信息
  void clearDanmakuTrackInfo() {
    _subtitleManager.clearSubtitleTrackInfo();
  }

  /// 重新触发自动检测并加载字幕（清除字幕缓存后调用）
  Future<void> redetectAndLoadSubtitle(String videoPath) =>
      _subtitleManager.autoDetectAndLoadSubtitle(videoPath);

  // 自动检测并加载同名字幕文件
  Future<void> _autoDetectAndLoadSubtitle(String videoPath) async {
    // 此方法不再需要，我们使用subtitleManager的方法代替
    await _subtitleManager.autoDetectAndLoadSubtitle(videoPath);
  }

  // 加载顶部弹幕屏蔽设置
  Future<void> _loadBlockTopDanmaku() async {
    final prefs = await SharedPreferences.getInstance();
    _blockTopDanmaku = prefs.getBool(SettingsKeys.blockTopDanmaku) ?? false;
    _notifyListeners();
  }

  // 设置顶部弹幕屏蔽
  Future<void> setBlockTopDanmaku(bool block) async {
    if (_blockTopDanmaku != block) {
      _blockTopDanmaku = block;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(SettingsKeys.blockTopDanmaku, block);
      _updateMergedDanmakuList();
    }
  }

  // 加载底部弹幕屏蔽设置
  Future<void> _loadBlockBottomDanmaku() async {
    final prefs = await SharedPreferences.getInstance();
    _blockBottomDanmaku = prefs.getBool(SettingsKeys.blockBottomDanmaku) ?? false;
    _notifyListeners();
  }

  // 设置底部弹幕屏蔽
  Future<void> setBlockBottomDanmaku(bool block) async {
    if (_blockBottomDanmaku != block) {
      _blockBottomDanmaku = block;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(SettingsKeys.blockBottomDanmaku, block);
      _updateMergedDanmakuList();
    }
  }

  // 加载滚动弹幕屏蔽设置
  Future<void> _loadBlockScrollDanmaku() async {
    final prefs = await SharedPreferences.getInstance();
    _blockScrollDanmaku = prefs.getBool(SettingsKeys.blockScrollDanmaku) ?? false;
    _notifyListeners();
  }

  // 设置滚动弹幕屏蔽
  Future<void> setBlockScrollDanmaku(bool block) async {
    if (_blockScrollDanmaku != block) {
      _blockScrollDanmaku = block;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(SettingsKeys.blockScrollDanmaku, block);
      _updateMergedDanmakuList();
    }
  }

  // 加载弹幕屏蔽词列表
  Future<void> _loadDanmakuBlockWords() async {
    final prefs = await SharedPreferences.getInstance();
    final blockWordsJson = prefs.getString(SettingsKeys.danmakuBlockWords);
    if (blockWordsJson != null && blockWordsJson.isNotEmpty) {
      try {
        final List<dynamic> decodedList = json.decode(blockWordsJson);
        _danmakuBlockWords = decodedList.map((e) => e.toString()).toList();
      } catch (e) {
        debugPrint('加载弹幕屏蔽词失败: $e');
        _danmakuBlockWords = [];
      }
    } else {
      _danmakuBlockWords = [];
    }
    _notifyListeners();
  }

  String _normalizeSpoilerMatchText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.replaceAll(RegExp(r'\s+'), ' ');
  }

  Future<void> _loadSpoilerPreventionEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    _spoilerPreventionEnabled =
        prefs.getBool(SettingsKeys.spoilerPreventionEnabled) ?? false;
    _notifyListeners();
  }

  Future<void> setSpoilerPreventionEnabled(bool enabled) async {
    if (_spoilerPreventionEnabled == enabled) {
      return;
    }
    if (enabled && !spoilerAiConfigReady) {
      debugPrint('[防剧透] 未配置AI接口，无法启用防剧透模式');
      return;
    }
    _spoilerPreventionEnabled = enabled;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(SettingsKeys.spoilerPreventionEnabled, enabled);

    _isSpoilerDanmakuAnalyzing = false;
    _spoilerDanmakuAnalysisHash = null;
    _spoilerDanmakuRunningAnalysisHash = null;
    _spoilerDanmakuTexts = <String>{};
    _spoilerDanmakuAnalysisDebounceTimer?.cancel();
    _spoilerDanmakuAnalysisDebounceTimer = null;
    _spoilerDanmakuPendingAnalysisHash = null;
    _spoilerDanmakuPendingRequestConfig = null;
    _spoilerDanmakuPendingTexts = null;
    _spoilerDanmakuPendingTargetVideoPath = null;

    _updateMergedDanmakuList();
  }

  SpoilerAiApiFormat _parseSpoilerAiApiFormat(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'gemini':
        return SpoilerAiApiFormat.gemini;
      case 'openai':
      default:
        return SpoilerAiApiFormat.openai;
    }
  }

  String _spoilerAiApiFormatToPrefs(SpoilerAiApiFormat format) {
    switch (format) {
      case SpoilerAiApiFormat.gemini:
        return 'gemini';
      case SpoilerAiApiFormat.openai:
        return 'openai';
    }
  }

  void _resetSpoilerDanmakuAnalysisForConfigChange() {
    _isSpoilerDanmakuAnalyzing = false;
    _spoilerDanmakuAnalysisHash = null;
    _spoilerDanmakuRunningAnalysisHash = null;
    _spoilerDanmakuTexts = <String>{};
    _spoilerDanmakuAnalysisDebounceTimer?.cancel();
    _spoilerDanmakuAnalysisDebounceTimer = null;
    _spoilerDanmakuPendingAnalysisHash = null;
    _spoilerDanmakuPendingRequestConfig = null;
    _spoilerDanmakuPendingTexts = null;
    _spoilerDanmakuPendingTargetVideoPath = null;
  }

  Future<void> _loadSpoilerAiSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final storedUseCustomKey = prefs.getBool(SettingsKeys.spoilerAiUseCustomKey);
    if (storedUseCustomKey != true) {
      _spoilerAiUseCustomKey = true;
      await prefs.setBool(SettingsKeys.spoilerAiUseCustomKey, true);
    } else {
      _spoilerAiUseCustomKey = true;
    }
    _spoilerAiApiFormat =
        _parseSpoilerAiApiFormat(prefs.getString(SettingsKeys.spoilerAiApiFormat));
    _spoilerAiApiUrl = prefs.getString(SettingsKeys.spoilerAiApiUrl) ?? '';
    _spoilerAiApiKey = prefs.getString(SettingsKeys.spoilerAiApiKey) ?? '';
    _spoilerAiModel = prefs.getString(SettingsKeys.spoilerAiModel) ?? 'gpt-5';
    final temp = prefs.getDouble(SettingsKeys.spoilerAiTemperature) ?? 0.5;
    _spoilerAiTemperature = temp.clamp(0.0, 2.0).toDouble();
    _spoilerAiDebugPrintResponse =
        prefs.getBool(SettingsKeys.spoilerAiDebugPrintResponse) ?? false;
    if (_spoilerPreventionEnabled && !spoilerAiConfigReady) {
      _spoilerPreventionEnabled = false;
      await prefs.setBool(SettingsKeys.spoilerPreventionEnabled, false);
    }
    _notifyListeners();
  }

  Future<void> updateSpoilerAiSettings({
    bool? useCustomKey,
    SpoilerAiApiFormat? apiFormat,
    String? apiUrl,
    String? apiKey,
    String? model,
    double? temperature,
    bool? debugPrintResponse,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    bool shouldRestartAnalysis = false;
    bool changed = false;

    if (useCustomKey != null && _spoilerAiUseCustomKey != true) {
      _spoilerAiUseCustomKey = true;
      await prefs.setBool(SettingsKeys.spoilerAiUseCustomKey, true);
      changed = true;
      shouldRestartAnalysis = true;
    }

    if (apiFormat != null && _spoilerAiApiFormat != apiFormat) {
      _spoilerAiApiFormat = apiFormat;
      await prefs.setString(
        SettingsKeys.spoilerAiApiFormat,
        _spoilerAiApiFormatToPrefs(apiFormat),
      );
      changed = true;
      shouldRestartAnalysis = true;
    }

    if (apiUrl != null && _spoilerAiApiUrl != apiUrl) {
      _spoilerAiApiUrl = apiUrl;
      await prefs.setString(SettingsKeys.spoilerAiApiUrl, apiUrl);
      changed = true;
      shouldRestartAnalysis = true;
    }

    if (apiKey != null && _spoilerAiApiKey != apiKey) {
      _spoilerAiApiKey = apiKey;
      await prefs.setString(SettingsKeys.spoilerAiApiKey, apiKey);
      changed = true;
      shouldRestartAnalysis = true;
    }

    if (model != null && _spoilerAiModel != model) {
      _spoilerAiModel = model;
      await prefs.setString(SettingsKeys.spoilerAiModel, model);
      changed = true;
      shouldRestartAnalysis = true;
    }

    if (temperature != null) {
      final resolved = temperature.clamp(0.0, 2.0).toDouble();
      if ((_spoilerAiTemperature - resolved).abs() > 0.0001) {
        _spoilerAiTemperature = resolved;
        await prefs.setDouble(SettingsKeys.spoilerAiTemperature, resolved);
        changed = true;
        shouldRestartAnalysis = true;
      }
    }

    if (debugPrintResponse != null &&
        _spoilerAiDebugPrintResponse != debugPrintResponse) {
      _spoilerAiDebugPrintResponse = debugPrintResponse;
      await prefs.setBool(SettingsKeys.spoilerAiDebugPrintResponse, debugPrintResponse);
      changed = true;
    }

    if (!changed) {
      return;
    }

    if (shouldRestartAnalysis) {
      _resetSpoilerDanmakuAnalysisForConfigChange();
      if (_spoilerPreventionEnabled) {
        _updateMergedDanmakuList();
        return;
      }
    }

    _notifyListeners();
  }

  Future<void> setSpoilerAiUseCustomKey(bool enabled) async {
    await updateSpoilerAiSettings(useCustomKey: true);
  }

  Future<void> setSpoilerAiApiFormat(SpoilerAiApiFormat format) async {
    await updateSpoilerAiSettings(apiFormat: format);
  }

  Future<void> setSpoilerAiApiUrl(String url) async {
    await updateSpoilerAiSettings(apiUrl: url);
  }

  Future<void> setSpoilerAiApiKey(String apiKey) async {
    await updateSpoilerAiSettings(apiKey: apiKey);
  }

  Future<void> setSpoilerAiModel(String model) async {
    await updateSpoilerAiSettings(model: model);
  }

  Future<void> setSpoilerAiTemperature(double temperature) async {
    await updateSpoilerAiSettings(temperature: temperature);
  }

  Future<void> setSpoilerAiDebugPrintResponse(bool enabled) async {
    await updateSpoilerAiSettings(debugPrintResponse: enabled);
  }

  // 添加弹幕屏蔽词
  Future<void> addDanmakuBlockWord(String word) async {
    if (word.isNotEmpty && !_danmakuBlockWords.contains(word)) {
      _danmakuBlockWords.add(word);
      await _saveDanmakuBlockWords();
      _updateMergedDanmakuList();
    }
  }

  // 移除弹幕屏蔽词
  Future<void> removeDanmakuBlockWord(String word) async {
    if (_danmakuBlockWords.contains(word)) {
      _danmakuBlockWords.remove(word);
      await _saveDanmakuBlockWords();
      _updateMergedDanmakuList();
    }
  }

  // 保存弹幕屏蔽词列表
  Future<void> _saveDanmakuBlockWords() async {
    final prefs = await SharedPreferences.getInstance();
    final blockWordsJson = json.encode(_danmakuBlockWords);
    await prefs.setString(SettingsKeys.danmakuBlockWords, blockWordsJson);
  }

  // 检查是否是正则表达式规则格式: 规则名称/表达式/
  bool _isRegexRule(String word) {
    if (!word.contains('/')) return false;
    final parts = word.split('/');
    return parts.length >= 3 && parts.first.isNotEmpty && parts.last.isEmpty;
  }

  // 解析正则表达式规则，返回 (规则名称, 正则表达式)
  (String, String)? _parseRegexRule(String word) {
    if (!_isRegexRule(word)) return null;
    final firstSlash = word.indexOf('/');
    final name = word.substring(0, firstSlash);
    final pattern = word.substring(firstSlash + 1, word.length - 1);
    return (name, pattern);
  }

  // 检查弹幕是否应该被屏蔽
  bool shouldBlockDanmaku(Map<String, dynamic> danmaku) {
    final String type = danmaku['type']?.toString() ?? '';
    final String content = danmaku['content']?.toString() ?? '';

    if (_blockTopDanmaku && type == 'top') return true;
    if (_blockBottomDanmaku && type == 'bottom') return true;
    if (_blockScrollDanmaku && type == 'scroll') return true;

    if (_spoilerPreventionEnabled && _spoilerDanmakuTexts.isNotEmpty) {
      final normalizedContent = _normalizeSpoilerMatchText(content);
      if (normalizedContent.isNotEmpty &&
          _spoilerDanmakuTexts.contains(normalizedContent)) {
        return true;
      }
    }

    for (final word in _danmakuBlockWords) {
      if (_isRegexRule(word)) {
        final parsed = _parseRegexRule(word);
        if (parsed != null) {
          final (_, pattern) = parsed;
          try {
            final regex = RegExp(pattern);
            if (regex.hasMatch(content)) {
              return true;
            }
          } catch (e) {
            debugPrint('正则表达式规则无效: $pattern, 错误: $e');
          }
        }
      } else {
        if (content.contains(word)) {
          return true;
        }
      }
    }

    for (final word in _pluginDanmakuBlockWords) {
      if (_isRegexRule(word)) {
        final parsed = _parseRegexRule(word);
        if (parsed != null) {
          final (_, pattern) = parsed;
          try {
            final regex = RegExp(pattern);
            if (regex.hasMatch(content)) {
              return true;
            }
          } catch (e) {
            debugPrint('插件正则表达式规则无效: $pattern, 错误: $e');
          }
        }
      } else {
        if (content.contains(word)) {
          return true;
        }
      }
    }
    return false;
  }
}
