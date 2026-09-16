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
      // 保持暂停状态不变，仅对当前帧做一次同位置 seek 触发渲染。
      if (_status != PlayerStatus.playing && hasVideo &&
          _position.inMilliseconds > 0) {
        Future<void>.delayed(const Duration(milliseconds: 200), () {
          if (_status != PlayerStatus.playing && hasVideo) {
            debugPrint('[VideoPlayerState] 回前台强制刷新画面帧');
            player.seek(position: _position.inMilliseconds);
          }
        });
      }
    }
  }
}
