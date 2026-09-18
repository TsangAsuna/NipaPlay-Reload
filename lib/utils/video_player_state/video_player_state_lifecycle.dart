part of video_player_state;

extension VideoPlayerStateLifecycle on VideoPlayerState {
  /// 处理应用生命周期变化，在移动端根据设置自动暂停。
  void handleAppLifecycleState(AppLifecycleState state) {
    if (!globals.isMobilePlatform) return;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (!_pauseOnBackground) return;
      if (_status == PlayerStatus.playing) {
        debugPrint('[VideoPlayerState] 应用进入后台，自动暂停播放');
        _wasPlayingBeforeBackground = true;
        pause();
      }
    } else if (state == AppLifecycleState.resumed) {
      // 后台因本功能自动暂停过 -> 回前台自动续播（erika/任何内核统一恢复）
      // 进后台前在播（_status==playing）或后台因自动暂停功能暂停过都恢复：
      // iOS 退后台系统/内核可能暂停播放（erika 时间停但字幕继续走 = 内核实际已暂停）：
      // 回前台只要视频存在且在播放位置就恢复。用户主动暂停的情况由 UI 层
      // 在暂停时清除 _wasPlayingBeforeBackground 兜底（暂无，play 幂等可接受）。
      // erika/libmpv 在 iOS 退后台时可能被系统暂停（无论是否开启自动暂停），
      // 回前台无条件恢复（play 幂等；用户主动暂停会在 UI 层清标志，暂无副作用）。
      if (hasVideo) {
        debugPrint('[VideoPlayerState] 回前台恢复播放');
        logPlayerEvent(
          'Player',
          '回前台恢复播放（内核 ${player.getPlayerKernelName()}）',
        );
        play();
      }
      // 回前台强制刷新一帧：iOS 切后台后渲染可能没跟上（画面灰/缺失），
      // 无论当前播放/暂停都同位置 seek 触发渲染（暂停时保持暂停态不变）。
      if (hasVideo && _position.inMilliseconds > 0) {
        Future<void>.delayed(const Duration(milliseconds: 200), () {
          if (!hasVideo) return;
          final pos = _position.inMilliseconds;
          debugPrint('[VideoPlayerState] 回前台强制刷新画面帧 pos=$pos');
          // 同位置 seek 会被解码器优化掉（日志刷新但画面不重绘）：
          // 先退 90ms 强制解码新帧，再回到原位置，暂停态保持不变。
          final back = pos > 200 ? pos - 90 : 0;
          player.seek(position: back);
          Future<void>.delayed(const Duration(milliseconds: 160), () {
            if (hasVideo) {
              player.seek(position: pos);
            }
          });
        });
      }
    }
  }
}
