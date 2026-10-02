// 播放器与后台播放。
//
// 播放：media_kit（libmpv）。B站 高清是 DASH 分流，不能用普通 video_player，
// 而 media_kit 支持「视频走 Media、音频走外挂音轨」这种组合，正好对上。
//
// 后台播放：audio_service。它提供一个前台服务 + MediaSession，
// 于是退到后台、锁屏都继续放，通知栏和锁屏上还有控制按钮。
// 这里做的就是把 audio_service 的播放指令转发给 media_kit 的 Player。
import 'package:audio_service/audio_service.dart';
import 'package:media_kit/media_kit.dart';

import 'media.dart';

late final BiliAudioHandler audioHandler;

/// 全局唯一的播放器，UI 和后台服务共用同一个实例
final Player biliPlayer = Player();

Future<void> initPlayer() async {
  audioHandler = await AudioService.init(
    builder: () => BiliAudioHandler(biliPlayer),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'moe.biliweb.playback',
      androidNotificationChannelName: '播放控制',
      // 常驻通知：后台播放必须有它，否则系统会随时回收进程
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
}

class BiliAudioHandler extends BaseAudioHandler with SeekHandler {
  BiliAudioHandler(this.player) {
    // 把 media_kit 的状态变化同步给系统（通知栏、锁屏、蓝牙耳机按键都靠它）
    player.stream.playing.listen((playing) => _push());
    player.stream.position.listen((_) => _push());
    player.stream.duration.listen((_) => _push());
    player.stream.buffering.listen((b) => _push(buffering: b));
    player.stream.completed.listen((done) async {
      if (done) {
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.completed,
          playing: false,
        ));
      }
    });
  }

  final Player player;

  /// 打开一个视频。videoUrl 为空则当纯音频播（无视频流的场合）。
  Future<void> open({
    required String videoUrl,
    String? audioUrl,
    required String title,
    required String artist,
    String? artUri,
  }) async {
    mediaItem.add(MediaItem(
      id: videoUrl,
      title: title,
      artist: artist,
      artUri: (artUri == null || artUri.isEmpty) ? null : Uri.parse(artUri),
    ));
    await player.open(
      Media(videoUrl, httpHeaders: kMediaHeaders),
      play: true,
    );
    // DASH 分流：视频轨已在播，这里把音频轨挂上，libmpv 负责同步
    if (audioUrl != null && audioUrl.isNotEmpty) {
      await player.setAudioTrack(AudioTrack.uri(audioUrl));
    }
    _push();
  }

  void _push({bool? buffering}) {
    final playing = player.state.playing;
    final position = player.state.position;
    final duration = player.state.duration;
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.rewind,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.fastForward,
        MediaControl.stop,
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 3],
      processingState: (buffering ?? player.state.buffering)
          ? AudioProcessingState.buffering
          : AudioProcessingState.ready,
      playing: playing,
      updatePosition: position,
      bufferedPosition: duration,
      speed: 1.0,
    ));
  }

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }
}
