part of video_player_state;

extension VideoPlayerStateLifecycle on VideoPlayerState {
  /// 处理应用生命周期变化，在移动端根据设置自动暂停。
  void handleAppLifecycleState(AppLifecycleState state) {
    if (!globals.isMobilePlatform) return;
    if (!_pauseOnBackground) return;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (_status == PlayerStatus.playing) {
        debugPrint('[VideoPlayerState] 应用进入后台，自动暂停播放');
        _wasPlayingBeforeBackground = true;
        pause();
      }
    } else if (state == AppLifecycleState.resumed) {
      // 后台因本功能自动暂停过 -> 回前台自动续播（erika/任何内核统一恢复）
      final resumeAfterBg = _wasPlayingBeforeBackground &&
          _status == PlayerStatus.paused;
      _wasPlayingBeforeBackground = false;
      if (resumeAfterBg) {
        debugPrint('[VideoPlayerState] 回前台自动恢复播放');
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
