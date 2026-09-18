# NipaPlay-Reload 静态代码审查报告

审查日期：2026-09-19
审查方式：`flutter analyze`（整库分析，过滤 vendored 包噪音）+ 按优先级人工精读
审查范围：lib/player_abstraction/、lib/utils/video_player_state.dart 及全部 part 文件、字幕相关服务与 UI、lib/danmaku_dfm/、lib/danmaku_next/、lib/danmaku_abstraction/、lib/providers/settings_provider.dart
说明：本报告只读不改，未修改任何源码，未执行任何 git 操作。

## flutter analyze 结果摘要

- 整库 `flutter analyze` 共 5580 行输出。其中绝大多数 error 级条目来自 vendored 包（packages/、third_party/ 及其 example），按约定视为噪音忽略。
- lib/ 与 test/ 范围内 error 级仅 1 条：`test\television_media_library_test.dart:325 - missing_required_argument`（见 F-01）。
- 优先级目录（player_abstraction、video_player_state 系列、字幕服务、弹幕目录）的 analyze 条目均为 lint 级（unused_local_variable、avoid_print、deprecated_member_use、unreachable_switch_default 等），未发现语法错误。lib/ 应用源码本身可编译。

## 发现清单

### F-01 [P0] [test/television_media_library_test.dart:325] 测试目标编译失败：缺少必填参数 newAnimeIds

问题描述：`AdaptiveMediaCollectionItems` 的构造函数中 `newAnimeIds` 为 required 参数（lib/media_library/adaptive_media_collection_view.dart:806），但测试中构造该组件时未传入，导致 `flutter test` 目标编译失败。这是 lib/test 范围内唯一的 error 级问题。

证据：
```dart
// lib/media_library/adaptive_media_collection_view.dart:800-811
class AdaptiveMediaCollectionItems extends material.StatelessWidget {
  const AdaptiveMediaCollectionItems({
    ...
    required this.newAnimeIds,
    ...
  });
```
```dart
// test/television_media_library_test.dart:325 附近
child: AdaptiveMediaCollectionItems(
  source: UnifiedMediaLibrarySource.local,
  sourceLabel: '本地媒体库',
  ...
  // 缺少 newAnimeIds 参数
```
analyze 输出：`error - The named parameter 'newAnimeIds' is required, but there's no corresponding argument. - test\television_media_library_test.dart:325:24 - missing_required_argument`

建议修法：在测试构造处补 `newAnimeIds: const <int>{},`。

### F-02 [P1] [lib/player_abstraction/erika_player_adapter.dart:684,1420-1432,1458-1459,883-910] 弹幕配置去重状态跨媒体会话泄漏：切集后内核样式配置永远不再下发

问题描述：`_flushDanmakuConfig` 用 `_lastAppliedDanmakuConfig` 对请求做差量去重（`differenceFrom`），只有与"上次已应用配置"不同的字段才会真正调用 `_player.setDanmakuConfig`。但 `setMedia()`（新媒体会话入口）清空了 `_lastDanmakuJson/_lastDanmakuEnabled/_lastDanmakuGlobalOffset` 却不清空 `_lastAppliedDanmakuConfig`。而同文件 `retryCurrentMediaLoad()` 在 `open()` 之后显式重放 `_lastAppliedDanmakuConfig`（第 1696-1725 行），说明作者模型中 `open()` 会重置内核侧弹幕配置。两者矛盾：从媒体 A 切到媒体 B 时，若用户没有改动任何弹幕设置，`_syncErikaDanmakuConfig()`（video_player_state_danmaku.dart:724，随 `_updateMergedDanmakuList` 每次媒体触发）发来的配置与 A 的快照完全相同，被去重为空补丁，内核从未收到 B 的弹幕样式，字号/透明度/显示区域/描边/阴影等静默回退到内核默认值。

证据：
```dart
// setMedia 只清列表级缓存，不清 _lastAppliedDanmakuConfig（883-910 行）
_externalSubtitleTrackIds.clear();
_externalSubtitleGeneration++;
_playbackWatchdogTimer?.cancel();
_stallRecoveryCount = 0;
_lastExternalSubtitlePath = null;
_lastDanmakuJson = null;
...
// _flushDanmakuConfig 差量去重（1420-1432 行）
final outgoingPatch = requestedPatch.differenceFrom(_lastAppliedDanmakuConfig);
if (outgoingPatch.isEmpty) {
  ...completers 全部成功完成，但内核什么都没收到...
}
// retryCurrentMediaLoad 却在 open() 后重放配置（1696 行），证明 open 会重置配置
final appliedConfig = _lastAppliedDanmakuConfig;
if (appliedConfig != null && !appliedConfig.isEmpty) { ... _player.setDanmakuConfig(...); }
```

建议修法：在 `setMedia()`（type 为 video/unknown 分支）与 `retryCurrentMediaLoad()` 的 `_player.open()` 前将 `_lastAppliedDanmakuConfig = null`，使下一次配置下发不再被去重；或让 `_flushDanmakuConfig` 携带一个"配置世代号"，open 后世代号变更时强制全量下发。

### F-03 [P1] [lib/utils/video_player_state/video_player_state_lifecycle.dart:13,16-31] 回前台恢复标志只写不读：手动暂停后切后台再回来会被强制续播

问题描述：`handleAppLifecycleState` 在进入后台自动暂停时写入 `_wasPlayingBeforeBackground = true`，但全仓库检索该标志只有这一处写入、零处读取。resumed 分支无条件 `if (hasVideo) play();`。而 `play()`（video_player_state_playback_controls.dart:589-722）并非幂等：`_status == PlayerStatus.paused` 时会调用 `playDirectly()` 恢复播放。因此用户手动暂停后切后台（无论是否开启"后台自动暂停"），回前台视频都会自动续播。代码注释自称"play 幂等可接受"，与实际实现不符；注释提到的兜底"用户主动暂停会在 UI 层清标志（暂无）"也从未实现。

证据：
```dart
// lifecycle.dart:8-31
if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
  if (!_pauseOnBackground) return;
  if (_status == PlayerStatus.playing) {
    _wasPlayingBeforeBackground = true;   // 全仓库唯一写入点，无任何读取点
    pause();
  }
} else if (state == AppLifecycleState.resumed) {
  if (hasVideo) {
    play();                               // 无条件恢复，paused 状态也会被拉起
  }
```
grep 结果：`_wasPlayingBeforeBackground` 仅出现在 video_player_state.dart:301（声明）与 lifecycle.dart:13（写入）。

建议修法：进入后台时记录真实播放意图（`_wasPlayingBeforeBackground = _status == PlayerStatus.playing`，手动暂停时置 false），resumed 分支仅在 `_wasPlayingBeforeBackground` 为真时 `play()`。

### F-04 [P2] [lib/player_abstraction/erika_player_adapter.dart:663-669,883-910,1495,1607] 停滞看门狗"每媒体设防"前提失效：`_positionEventCount`/`_lastNativePositionEventAt` 永不复位

问题描述：`_armPlaybackWatchdog` 的注释声明"只在'本媒体曾收到过原生位置事件'的 Play 上设防，避免误伤首次起播时的网络缓冲"，实现依据是 `_positionEventCount == 0` 即不设防。但 `_positionEventCount` 与 `_lastNativePositionEventAt` 只在 `_handleEvent` 中累加/刷新，`setMedia()`、`state = stopped`、`retryCurrentMediaLoad()` 均不复位。结果：播放过第一个媒体后，计数永久大于 0，此后每个新媒体的第一次起播都会布防看门狗；若新媒体起播缓冲超过约 3 秒（无位置事件），3 秒定时器触发时按"距上次事件"计算的静默时长必然超过 2500ms 阈值（时间戳来自上一个媒体），于是先触发 pause/play 唤醒（缓冲期画面/声音抖动），再无效则执行 `retryCurrentMediaLoad()` 重开媒体，最多 3 次——把正常网络缓冲误判为内核停摆并中断它。附带影响：`hasReceivedRealPosition`（供 ticker 错误检测的 `isWaitingForFirstRealPosition` 守卫使用，video_player_state_navigation.dart:1423-1426）同样是跨媒体累计值，第二个媒体起播时恒为 true，守卫失效。

证据：
```dart
// 仅由原生 positionChanged 事件递增（1940-1941 行）
_positionEventCount++;
_lastNativePositionEventAt = DateTime.now();
// setMedia 停滞看门狗清理不完整（902-904 行）
_playbackWatchdogTimer?.cancel();
_stallRecoveryCount = 0;          // 只清恢复计数，不清事件计数与时间戳
// 布防判定（1495 行）——声称"本媒体"实为适配器生命周期
if (_positionEventCount == 0) {
  return;
}
```

建议修法：在 `setMedia()` 的 video/unknown 分支与 `state` setter 的 stopped 分支中复位 `_positionEventCount = 0; _lastNativePositionEventAt = null;`，使注释所声明的"每媒体"语义成立。

### F-05 [P2] [lib/utils/video_player_state/video_player_state_playback_controls.dart:948-979 + lib/player_abstraction/erika_player_adapter.dart:912-923,1085-1105] 暂停态 seek 的 100ms 延迟暂停与异步 playDirectly 竞态：暂停被吞、视频意外转为播放

问题描述：`seekTo()` 在暂停状态下先 `player.state = PlaybackState.playing` 再 `Future.delayed(100ms)` 后恢复暂停。Erika 适配器的 `state` setter 经 `_dispatchStateCommand('play', playDirectly)` 异步下发，`_state` 要等 `ensureCreated()+play()` 两个跨平台异步调用完成后才置为 playing；而 `pauseDirectly()` 开头 `if (_state != PlayerPlaybackState.playing) return;`。若 100ms 内 playDirectly 尚未完成（首次起播/慢内核完全可能），延迟到达的暂停命令直接 return，随后 playDirectly 完成并开始播放——用户"暂停中拖动进度条"最终变成继续播放。MDK/MediaKit 的 `state` setter 为同步属性赋值（`_state = value` 立即生效），不受影响；该竞态为 Erika 特有。

证据：
```dart
// playback_controls.dart seekTo
if (_status == PlayerStatus.paused) {
  player.state = PlaybackState.playing;   // Erika: 异步 playDirectly，_state 稍后才变 playing
  _setStatus(PlayerStatus.playing);
}
...
Future.delayed(const Duration(milliseconds: 100), () {
  _isSeeking = false;
  if (!wasPlayingBeforeSeek && _status == PlayerStatus.playing) {
    player.state = PlaybackState.paused;  // Erika: pauseDirectly 中 _state != playing 时直接 return
    _setStatus(PlayerStatus.paused);
  }
});
// erika_player_adapter.dart pauseDirectly
_playbackWatchdogTimer?.cancel();
if (_state != PlayerPlaybackState.playing) {
  return;                                  // playDirectly 未完成时暂停被静默吞掉
}
```

建议修法：`seekTo` 的恢复暂停改为 `player.pauseDirectly()` 并等待其真正下发（或让 Erika 的 state setter 在下发 play 前同步置 `_state = playing`，使后发的 pauseDirectly 能正确排队/生效）；亦可在适配器内对 play/pause 命令做串行化队列。

### F-06 [P2] [lib/services/subtitle_service.dart:18,41-71 + lib/utils/subtitle_manager.dart:267-325 + lib/themes/nipaplay/widgets/subtitle_tracks_menu.dart:86-127] 同一 SharedPreferences 键存在三方写入，只有一方维护内存缓存：Cupertino 字幕面板可见陈旧列表，按索引删除可能删错条目

问题描述：`external_subtitles_<videoHashKey>` 与 `last_active_subtitle_<videoHashKey>` 两个键有三个写入方：
1. `SubtitleService`（读写均经过内存缓存 `_externalSubtitlesCache`，首次读取后缓存命中短路）；
2. `SubtitleManager._persistExternalSubtitleSelection`（直写 prefs，绕过 SubtitleService 缓存）；
3. `subtitle_tracks_menu.dart`（直读直写 prefs）。

SubtitleService 的缓存没有任何跨写入方的失效机制（仅 clearCache/clearAllCache）。CupertinoSubtitleTracksPane 完全依赖 `SubtitleService.loadExternalSubtitles`：一旦它为某个视频缓存过列表（哪怕空列表），之后由 SubtitleManager 自动挂载持久化的字幕或 nipaplay 菜单的增删改在 Cupertino 面板中全部不可见（直到应用重启）。更严重的是 Cupertino 面板的 `_removeExternalSubtitle` 按索引删除（`removeExternalSubtitle(path, index)`），当其列表已陈旧时，索引会指向另一份真实列表中的不同条目，删错字幕。

证据：
```dart
// subtitle_service.dart：缓存命中短路，外部直写不会刷新它
if (_externalSubtitlesCache.containsKey(videoHashKey)) {
  return _externalSubtitlesCache[videoHashKey]!;
}
// subtitle_manager.dart:276-314 直写同一键（绕过缓存）
await prefs.setString(subtitlesKey, json.encode(subtitles));
// subtitle_tracks_menu.dart:126-127 同样直写
await prefs.setString('external_subtitles_$videoHashKey', json.encode(_externalSubtitles));
```

建议修法：统一收口到 SubtitleService（SubtitleManager 与 nipaplay 菜单改调 `addExternalSubtitles`/`removeExternalSubtitle`/`setExternalSubtitleActive`），或在 `_persistExternalSubtitleSelection` 与菜单写入后调用 `SubtitleService().clearCache(videoPath)`；Cupertino 删除改为按 path 匹配。

### F-07 [P3,待确认] [lib/player_abstraction/erika_player_adapter.dart:1937-1961] seek fence 内丢弃位置事件时连带丢弃 duration/视频尺寸更新

问题描述：positionChanged 事件处理中，若处于 seek fence（1.5 秒）且事件位置距 seek 目标超过 1500ms，直接 `return`。该 return 同时跳过函数后半段的 `_mediaInfo` 更新（`event.duration > 0` 时的 duration 写入、`event.video` 尺寸写入）。若 Erika 通过 positionChanged 事件携带 duration（首次时长尚未就绪时），恢复位置 seek 后的 1.5 秒内 `waitUntilMediaReady` 的轮询会被延迟。由于未能确认 Erika 事件是否在 positionChanged 中携带 duration，标注待确认。

证据：
```dart
if (seekTarget != null && fenceUntil != null && now.isBefore(fenceUntil)) {
  final distance = (eventPositionMs - seekTarget).abs();
  if (distance > 1500) {
    return;          // 同时跳过下方 updatedInfo（duration/video）处理
  }
```

建议修法：把 fence 判定提前记录 `shouldSkipPositionUpdate` 标志，只跳过 `_lastPositionMs/_lastPositionUpdate` 赋值，不跳过 mediaInfo 更新。

### F-08 [P3] [lib/player_abstraction/erika_player_adapter.dart:1637-1735] retryCurrentMediaLoad 不恢复内嵌字幕/音轨选择

问题描述：自愈重开媒体后恢复了音量、倍速、字幕缩放、弹幕列表/配置与外挂字幕，但 `_activeSubtitleTracks = const []` 且未记录/重选用户之前选中的内嵌字幕轨（`selectSubtitleTrack`）与音轨（`selectAudioTrack`）。重开后内嵌字幕与音轨回退到内核默认选择，用户选择丢失（外挂字幕有 `_lastExternalSubtitlePath` 兜底，内嵌没有）。

证据：
```dart
_externalSubtitleTrackIds.clear();
_externalSubtitleGeneration++;
_activeSubtitleTracks = const <int>[];   // 内嵌轨选择被清空且无恢复逻辑
await _player.open(_media);
```

建议修法：重开前保存 `_activeSubtitleTracks`/`_activeAudioTracks`，`open()` 完成且轨道事件到达后重放选择。

### F-09 [P3] [lib/player_abstraction/erika_player_adapter.dart:805-836] activeSubtitleTracks setter 对越界索引静默接受，造成 UI 与内核状态不一致

问题描述：setter 先无条件 `_activeSubtitleTracks = List<int>.from(value)`，索引越界时只打 trace 不做任何事也不回滚。UI（字幕菜单）此时认为轨道已激活，内核实际未选择任何轨道，激活状态不一致；且后续轨道事件到来前 getter 一直返回越界值。

证据：
```dart
set activeSubtitleTracks(List<int> value) {
  _activeSubtitleTracks = List<int>.from(value);   // 先写状态
  ...
  } else {
    _subtitleTrace('activeSubtitleTracks ignored out-of-range index=$index ...');  // 仅 trace
  }
```

建议修法：越界时不更新 `_activeSubtitleTracks`（保持原值），或在轨道事件到达后重放最近一次请求。

### F-10 [P3] [lib/player_abstraction/erika_player_adapter.dart:1503-1555,1572-1601] 看门狗健康分支不重布防；自愈失败路径不重布防，剩余重试预算作废

问题描述：(1) 看门狗是一次性检查：健康分支（事件仍在流动）直接 return，不再重设 3 秒定时器，此后本次播放内发生的停滞不会再被检测（与"回前台停滞"的设计定位一致，但值得知晓）。(2) `_recoverStalledPlayback` 中 `retryCurrentMediaLoad()` 返回 false 或抛异常时，finally 只复位 `_stallRecoveryInFlight`，不重新布防；`_stallRecoveryCount` 的 3 次预算在首次失败后即被放弃，用户只能手动干预。

证据：
```dart
if (silence != null && silence < _stallEventSilenceThreshold) {
  _stallRecoveryCount = 0;
  _stallNudgeAttempted = false;
  return;                       // 不重布防
}
...
final recovered = await retryCurrentMediaLoad();
if (!recovered || _disposed || !wasPlaying) {
  return;                       // 失败路径不重布防
}
```

建议修法：失败路径按剩余预算重新 `_armPlaybackWatchdog(resetNudgeAttempt: false)`；健康分支是否长期布防属产品决策，可保持现状但建议补注释。

### F-11 [P3] [lib/player_abstraction/erika_player_adapter.dart:967-972] disposeAsync 将未应用的弹幕配置 completer 以成功收尾

问题描述：`disposeAsync` 对 `_pendingDanmakuConfigCompleters` 一律 `completer.complete()`，而 `setDanmakuConfig` 的调用方以返回的 Future 判定"配置已应用"。dispose 时尚未下发的配置会谎报成功。

证据：
```dart
for (final completer in _pendingDanmakuConfigCompleters) {
  if (!completer.isCompleted) {
    completer.complete();       // 实际未发送到内核
  }
}
```

建议修法：改为 `completeError(StateError(...))` 或在文档中注明 dispose 时静默丢弃。

### F-12 [P3] [lib/player_abstraction/erika_player_adapter.dart:274-280,358-421] 回前台强制重绑可能被在途 bind 吞掉（待确认）

问题描述：`didChangeAppLifecycleState(resumed)` 置 `_isBound = false` 后经 `_scheduleAttach` 重绑，但 `_attachOverlaySurface` 开头 `if (!mounted || _isBound || _bindInFlight || kIsWeb) return;`——若 resume 恰好有 bind 在途，本次重绑被吞，在途 bind 完成后把"已被系统回收的 surface"标记为已绑定，叠加层保持黑屏。触发窗口窄（bind 恰好在后台/前台切换瞬间在途），标注待确认。

证据：
```dart
Future<void> _attachOverlaySurface() async {
  if (!mounted || _isBound || _bindInFlight || kIsWeb) {
    return;
  }
```

建议修法：resume 路径使用"强制重绑"标志（如 `_rebindRequested = true`），在途 bind 完成后检查该标志再次发起 attach。

### F-13 [P3] [lib/player_abstraction/player_factory.dart:170-208,404-415] 设置加载/保存的异常处理不对称

问题描述：`_loadSettingsSync` 中 `SharedPreferences.getInstance().then(...)` 无 onError，实例获取失败会成为未处理异步异常；`saveHttpProxy` 是唯一没有 try/catch 的 save 系列（其余 save 均有），prefs 写失败会向调用方抛出。

证据：
```dart
SharedPreferences.getInstance().then((prefs) { ... });   // 无 onError
...
static Future<void> saveHttpProxy(String proxy) async {
  ...
  await preferences.setString(SettingsKeys.playerHttpProxy, resolved);  // 无 try/catch
```

建议修法：补 `onError` 与 try/catch，行为对齐其他 save 方法。

### F-14 [P3] [lib/providers/settings_provider.dart:17,78-172] `_prefs` 为 late：加载完成前调用任何 setter 即崩溃

问题描述：`_loadSettings()` 异步完成前（构造后首个 await 窗口内），任何 setter（如 `setBlurPower`、`setDanmakuSupersample`）访问 `_prefs` 会抛 `LateInitializationError`。启动早期/竞态路径下调用 setter 的 UI 未做防护。

证据：
```dart
late SharedPreferences _prefs;
SettingsProvider() {
  _danmakuSupersample = _defaultDanmakuSupersample();
  _loadSettings();      // 异步
}
Future<void> setBlurEnabled(bool enable) async {
  _blurPower = enable ? 10.0 : 0.0;
  await _prefs.setDouble(...);   // _prefs 未初始化即抛
```

建议修法：构造函数中初始化为空实例或使用 `SharedPreferencesAsync`/缓存实例；或 setter 内对未初始化做降级。

### F-15 [P3] [lib/utils/video_player_state/video_player_state_navigation.dart:825] Ticker 回调为 async：存在重叠执行窗口

问题描述：`Ticker((elapsed) async { ... })` 的回调体内有 await（如播放结束分支中的 `await _updateWatchHistory(forceRemoteSync: true)`）。SchedulerBinding 不会等待 async 回调，下一 vsync 可能与上一帧未完成的异步体交叠执行，共享可变状态（_position/_playbackTimeMs/锚点字段等）存在交错风险。节流逻辑降低了概率但不消除。

证据：
```dart
_uiUpdateTicker ??= Ticker((elapsed) async {
  ...
  await _updateWatchHistory(forceRemoteSync: true);   // EOF 分支
```

建议修法：回调保持同步，把异步工作（观看记录写入等）用 unawaited 派发到独立任务并加世代守卫。

### F-16 [P3] [lib/utils/video_player_state/video_player_state_preferences.dart:1919-1928] setSubtitleDelaySeconds 持久化未钳制值，与 setSubtitleScale 行为不一致

问题描述：`setSubtitleScale` 先钳制再持久化；`setSubtitleDelaySeconds` 把原始值直接写 prefs，仅 getter `subtitleDelaySeconds` 读取时按当前视频时长动态钳制。跨视频恢复时依赖时长就绪时机，可能出现"设置面板显示值与存储值不一致"的窗口；该差异目前被 initializePlayer 第 741-745 行的"时长就绪后重应用"逻辑兜住，属一致性弱点而非直接故障。

证据：
```dart
Future<void> setSubtitleDelaySeconds(double seconds) async {
  if ((_subtitleDelaySeconds - seconds).abs() < 0.0001) return;
  _subtitleDelaySeconds = seconds;                 // 未 clamp
  ...
  await prefs.setDouble(_subtitleDelayKey, seconds);
```

建议修法：与 scale 一致：持久化前经 `_resolveSubtitleDelaySecondsForCurrentVideo` 钳制（保留原始值需另立键）。

### F-17 [P3] [lib/themes/nipaplay/widgets/subtitle_tracks_menu.dart:389-411] 远程字幕多挂循环把列表中所有历史 SRT/VTT 一并重新挂载并激活

问题描述：注释写"多挂：所有选中的 SRT/VTT 叠加激活"，但循环遍历的是整个 `_externalSubtitles`（从 prefs 加载的完整历史列表），不是本次对话框勾选的 `selected`。用户曾添加但已取消激活的 SRT 会被重新挂载并标记 isActive=true。

证据：
```dart
if (_externalSubtitles.isNotEmpty) {
  var applied = false;
  for (var i = 0; i < _externalSubtitles.length; i++) {   // 遍历全量历史列表
    ...
    if (ext == '.srt' || ext == '.vtt') {
      await videoState.addExternalSubtitleToStack(subPath);
      sub['isActive'] = true;                             // 全部激活
```

建议修法：仅对本次 `selected` 映射到的列表条目执行叠加挂载与激活。

### F-18 [P3] [lib/themes/nipaplay/widgets/subtitle_tracks_menu.dart:182-195] 重复应用既有字幕时不持久化激活状态

问题描述：`_loadExternalSubtitle` 中选择的文件已存在于列表时，走 `_applyExternalSubtitle` 后直接 return，跳过 `_saveExternalSubtitles`，isActive 变更只存在于内存，重启后丢失。

证据：
```dart
if (existingIndex >= 0) {
  _applyExternalSubtitle(videoState, filePath, existingIndex);
  ...
  return;                       // 未调用 _saveExternalSubtitles
}
```

建议修法：return 前补 `await _saveExternalSubtitles(context);`。

### F-19 [P3] [lib/danmaku_dfm/dfm_plus_overlay.dart:647-652] _runUpdateLoop 异常时无条件 _queueUpdate：确定性错误形成热循环

问题描述：循环体 catch 中 `_queueUpdate()` 立即重试且无退避；若 `_bridge.configure`/`setFrame` 等平台通道调用持续同步抛错（如引擎未就绪、参数非法），将形成持续的微任务级错误重试循环，空耗 CPU。vsync 门控只覆盖常规调度，不覆盖 catch 路径。

证据：
```dart
} catch (_) {
  // Keep overlay alive and retry on next frame.
  _queueUpdate();               // 无退避、无错误分类
} finally {
```

建议修法：引入最小重试间隔（如 50-100ms）或连续失败计数熔断。

### F-20 [P3,待确认] [lib/utils/video_player_state/video_player_state_player_setup.dart:1176-1217 + video_player_state_preferences.dart:18-50] 非媒体准备阶段的初始化失败进入无上界的异步自愈重试环

问题描述：initializePlayer 的通用 catch 调用 `_tryRecoverFromError()`，后者 1 秒后再次 `initializePlayer(path,...)`；若失败发生在"媒体准备开始前"的通用路径（如 PlaybackSourceService.resolve 反复抛错），每次失败都会再次进入 recover，形成无上界的异步重试环（async 链不累积栈，但会无限消耗资源并反复刷新错误状态）。媒体准备阶段（prepare 抛错）走 `_notifySeriousPlaybackErrorAfterFrame` 弹窗退场路径，可打断循环，故实际可触发性取决于失败阶段，标注待确认。

证据：
```dart
} catch (e) {
  ...
  _error = '初始化视频播放器时出错: $e';
  _setStatus(PlayerStatus.error, message: '播放器初始化失败');
  _tryRecoverFromError();       // 内部再次 initializePlayer，失败再递归
}
```

建议修法：为 `_tryRecoverFromError` 增加每路径重试计数（如最多 2 次），超限后停在错误态。

### F-21 [P3] [lib/themes/cupertino/widgets/player_menu/cupertino_subtitle_tracks_pane.dart:44-58,311-328] Cupertino 面板依赖陈旧缓存的索引删除 + 语言名回退解析不稳定

问题描述：(1) `_removeExternalSubtitle` 用 `_subtitleService.removeExternalSubtitle(path, index)` 按索引删除；面板列表来自 SubtitleService 缓存（见 F-06），缓存陈旧时索引错位可删除错误条目。(2) 内嵌轨道语言显示 `getLanguageName(track.language ?? track.toString())`——把整个对象 toString 作为语言输入，几乎必然返回"未知"，与 nipaplay 菜单经 SubtitleManager 解析出的友好语言名不一致。

证据：
```dart
await _subtitleService.removeExternalSubtitle(path, index);   // 按索引
...
final String language = _subtitleService.getLanguageName(track.language ?? track.toString());
```

建议修法：删除改为按 path 定位索引；语言名解析改用 track.language/code 专用回退（如取 title），不要传 toString()。

## 已排查并排除的疑点（非问题）

- `Player.setNativeDanmakuConfig` 未透传 blockTop/blockBottom/blockScroll/blockWords：Erika 原生弹幕由 Dart 侧先经 `shouldBlockDanmaku` 过滤后再 `loadNativeDanmaku(filteredList)` 喂入（video_player_state_danmaku.dart:725），屏蔽在列表层完成，属设计内。
- `setDanmakuAutoLoadStrategy(manual)` 不持久化 'manual'：manual 是遗留别名，`resolveDanmakuAutoLoadSettings` 经 `skipDanmakuMatching` 统一解析，行为自洽。
- `next2_platform_support.dart` 两个 unreachable_switch_default 警告：标准 TargetPlatform 枚举穷尽所致，default 分支为 HarmonyOS（ohos fork 新增枚举值）保留，属分析器假阳性。
- `PlaybackPositionStore.flush()` 的 do/while 收敛循环：逻辑正确，能覆盖 await 期间新入队的保存。
- `_getVideoPosition` 直读 prefs 前先 `PlaybackPositionStore.instance.flush()`，顺序正确，未绕过内存缓存造成脏读。
- Erika 看门狗活性信号（`_lastNativePositionEventAt` 在 fence 判定前更新）不受 seek fence 早退影响。

## 汇总表（按严重度排序）

| 编号 | 严重度 | 位置 | 问题摘要 |
|------|--------|------|----------|
| F-01 | P0 | test/television_media_library_test.dart:325 | AdaptiveMediaCollectionItems 缺必填参数 newAnimeIds，测试目标编译失败 |
| F-02 | P1 | player_abstraction/erika_player_adapter.dart:684,1420-1432 | 弹幕配置去重跨媒体泄漏，切集后内核样式配置不再下发 |
| F-03 | P1 | utils/video_player_state/video_player_state_lifecycle.dart:13-31 | _wasPlayingBeforeBackground 只写不读，手动暂停回前台被强制续播 |
| F-04 | P2 | player_abstraction/erika_player_adapter.dart:663-669,883-910 | 看门狗事件计数/时间戳不复位，新媒体起播缓冲可误触发唤醒与重开媒体 |
| F-05 | P2 | playback_controls.dart:948-979 + erika_player_adapter.dart | 暂停态 seek 的延迟暂停被异步 playDirectly 竞态吞掉（Erika 特有） |
| F-06 | P2 | subtitle_service.dart / subtitle_manager.dart / subtitle_tracks_menu.dart | 同键三方写入仅一方有缓存，Cupertino 面板陈旧列表且按索引可删错 |
| F-07 | P3 | erika_player_adapter.dart:1937-1961 | seek fence 早退连带丢弃 duration/尺寸更新（待确认） |
| F-08 | P3 | erika_player_adapter.dart:1637-1735 | 自愈重开不恢复内嵌字幕/音轨选择 |
| F-09 | P3 | erika_player_adapter.dart:805-836 | activeSubtitleTracks setter 越界静默接受，状态不一致 |
| F-10 | P3 | erika_player_adapter.dart:1503-1601 | 看门狗健康分支/自愈失败不重布防，重试预算作废 |
| F-11 | P3 | erika_player_adapter.dart:967-972 | dispose 将未应用弹幕配置谎报为成功 |
| F-12 | P3 | erika_player_adapter.dart:274-280,358-421 | 回前台重绑可被在途 bind 吞掉（待确认） |
| F-13 | P3 | player_factory.dart:170-208,404-415 | 设置加载/保存异常处理不对称，存在未处理异步异常路径 |
| F-14 | P3 | providers/settings_provider.dart:17 | late _prefs 在加载完成前调用 setter 即抛 LateInitializationError |
| F-15 | P3 | video_player_state_navigation.dart:825 | Ticker async 回调存在重叠执行窗口 |
| F-16 | P3 | video_player_state_preferences.dart:1919-1928 | 字幕延迟持久化未钳制，与 scale 行为不一致 |
| F-17 | P3 | subtitle_tracks_menu.dart:389-411 | 远程多挂循环把全部历史 SRT/VTT 重新挂载激活 |
| F-18 | P3 | subtitle_tracks_menu.dart:182-195 | 重复应用既有字幕不持久化激活状态 |
| F-19 | P3 | danmaku_dfm/dfm_plus_overlay.dart:647-652 | 更新循环异常重试无退避，可形成热循环 |
| F-20 | P3 | player_setup.dart + preferences.dart | 非媒体准备阶段失败的无上界异步自愈重试环（待确认） |
| F-21 | P3 | cupertino_subtitle_tracks_pane.dart:44-58,311-328 | 依赖陈旧缓存按索引删除；语言名回退用 toString 解析几乎必然未知 |

统计：共 21 条 —— P0 x 1，P1 x 2，P2 x 3，P3 x 15（其中 2 条标注待确认）。
