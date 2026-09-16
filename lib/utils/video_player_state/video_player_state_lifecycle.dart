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
        pause();
      }
    } else if (state == AppLifecycleState.resumed) {
      // 回前台强制刷新一帧：iOS 切后台后渲染可能没跟上（画面灰/缺失），
      // 无论当前播放/暂停都同位置 seek 触发渲染（暂停时保持暂停态不变）。
      if (hasVideo && _position.inMilliseconds > 0) {
        Future<void>.delayed(const Duration(milliseconds: 200), () {
          if (hasVideo) {
            debugPrint('[VideoPlayerState] 回前台强制刷新画面帧');
            player.seek(position: _position.inMilliseconds);
          }
        });
      }
    }
  }
}
