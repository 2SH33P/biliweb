// 播放器与后台播放。
//
// 播放：media_kit（libmpv）。B站 高清是 DASH 分流，不能用普通 video_player，
// 而 media_kit 支持「视频走 Media、音频走外挂音轨」这种组合，正好对上。
//
// 后台播放：audio_service。它提供一个前台服务 + MediaSession，
// 于是退到后台、锁屏都继续放，通知栏和锁屏上还有控制按钮。
//
// 重要：初始化必须容错。audio_service 在某些机型/系统版本上会初始化失败甚至卡住，
// 早期版本把它 await 在 runApp 之前，结果首帧永远画不出来，App 卡在图标页。
// 现在改成：界面先出来，初始化放在后面，失败就降级成「能播但没有后台服务」。
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'media.dart';

late final BiliAudioHandler audioHandler;

/// 64MiB 前向缓存：B站 DASH 分片的码率不低，缓存太小会频繁 stall。
const int kBufferBytes = 64 * 1024 * 1024;

/// 全局唯一的播放器，UI 和后台服务共用同一个实例。main() 会在
/// runApp 前同步完成 MediaKit.ensureInitialized。
final Player biliPlayer =
    Player(configuration: const PlayerConfiguration(bufferSize: kBufferBytes));

/// 与全局播放器配对的唯一 VideoController。media_kit 要求一个 Player 只配一个
/// controller，详情页内嵌播放与独立播放页共用它，避免多个 controller 抢视频输出。
/// main() 会在 runApp 前完成 MediaKit.ensureInitialized。
late final VideoController biliVideoController = VideoController(biliPlayer);

/// libmpv 缓存/网络参数：前向 64MiB、回退 16MiB、预读 20s、超时 15s。
const Map<String, String> kMpvCacheProps = {
  'cache': 'yes',
  'demuxer-max-bytes': '64MiB',
  'demuxer-max-back-bytes': '16MiB',
  'demuxer-readahead-secs': '20',
  'network-timeout': '15',
};

bool mediaKitReady = false;
bool audioServiceReady = false;

/// 初始化过程中的错误，非空就显示在界面上，方便定位
String playerInitError = '';

/// 绝不抛异常、绝不无限等待：失败只记录，不影响别的功能
Future<void> initPlayer() async {
  try {
    mediaKitReady = true;
    // 缓存/超时参数在打开媒体前就位（失败只记日志，不影响播放）
    await applyCacheConfig(biliPlayer);
  } catch (e) {
    playerInitError = 'libmpv 初始化失败：$e';
    debugPrint(playerInitError);
    return;
  }
  try {
    audioHandler = await AudioService.init(
      builder: () => BiliAudioHandler(biliPlayer),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'moe.biliweb.playback',
        androidNotificationChannelName: '播放控制',
        // 常驻通知：后台播放必须有它，否则系统会随时回收进程
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    ).timeout(const Duration(seconds: 12));
    audioServiceReady = true;
  } catch (e) {
    playerInitError = '后台播放服务初始化失败（不影响应用内播放）：$e';
    debugPrint(playerInitError);
  }
}

/// 统一的播放入口：后台服务可用就走它，否则直接喂 media_kit。
/// videoUrls/audioUrls 是完整候选列表（含 backup），主 URL 失败时依次回退。
Future<void> openMedia({
  required String videoUrl,
  String? audioUrl,
  List<String> videoUrls = const <String>[],
  List<String> audioUrls = const <String>[],
  required String title,
  required String artist,
  String? artUri,
}) async {
  if (audioServiceReady) {
    return audioHandler.open(
      videoUrl: videoUrl,
      audioUrl: audioUrl,
      videoUrls: videoUrls,
      audioUrls: audioUrls,
      title: title,
      artist: artist,
      artUri: artUri,
    );
  }
  await applyCacheConfig(biliPlayer);
  await openVideoWithFallback(biliPlayer, mergeUrls(videoUrl, videoUrls), title);
  final audios = mergeUrls(audioUrl, audioUrls);
  if (audios.isNotEmpty) await setAudioWithFallback(biliPlayer, audios);
}

/// 依次尝试视频候选 URL。open 返回不代表网络媒体已经可用：必须等到
/// duration/playing 的真实事件；错误流或 10 秒超时则继续下一个 CDN。
Future<String> openVideoWithFallback(Player player, List<String> urls, String title) async {
  Object? lastErr;
  for (final url in urls) {
    if (url.isEmpty) continue;
    final ready = Completer<void>();
    late final StreamSubscription<Duration> durationSub;
    late final StreamSubscription<bool> playingSub;
    late final StreamSubscription<String> errorSub;
    void succeed() {
      if (!ready.isCompleted) ready.complete();
    }
    void fail(Object error) {
      if (!ready.isCompleted) ready.completeError(error);
    }
    durationSub = player.stream.duration.listen((value) {
      if (value > Duration.zero) succeed();
    });
    playingSub = player.stream.playing.listen((value) {
      if (value) succeed();
    });
    errorSub = player.stream.error.listen((value) => fail(Exception(value)));
    final readiness = ready.future.timeout(const Duration(seconds: 10));
    try {
      await player.open(Media(url, httpHeaders: kMediaHeaders), play: true);
      await readiness;
      // 主视频确认加载后再重写全局请求头，供随后 audio-add 使用。
      await applyMediaHeaders(player);
      return url;
    } catch (e) {
      lastErr = e;
      debugPrint('打开失败，尝试备选地址：$url（$e）');
    } finally {
      await durationSub.cancel();
      await playingSub.cancel();
      await errorSub.cancel();
    }
  }
  throw Exception('所有播放地址都失败（$title）：$lastErr');
}

/// 依次尝试音轨候选 URL。setAudioTrack 返回不代表 audio-add 已加载；
/// 等当前音轨变为目标 URI，错误流或短超时则继续下一个 CDN。
Future<void> setAudioWithFallback(Player player, List<String> urls) async {
  Object? lastErr;
  for (final url in urls) {
    if (url.isEmpty) continue;
    final target = AudioTrack.uri(url);
    final ready = Completer<void>();
    late final StreamSubscription<Track> trackSub;
    late final StreamSubscription<String> errorSub;
    void confirm(Track track) {
      if (track.audio == target && !ready.isCompleted) ready.complete();
    }
    trackSub = player.stream.track.listen(confirm);
    errorSub = player.stream.error.listen((value) {
      if (!ready.isCompleted) ready.completeError(Exception(value));
    });
    final readiness = ready.future.timeout(const Duration(seconds: 3));
    try {
      await player.setAudioTrack(target);
      confirm(player.state.track);
      await readiness;
      return;
    } catch (e) {
      lastErr = e;
      debugPrint('音轨加载失败，尝试备选地址：$url（$e）');
    } finally {
      await trackSub.cancel();
      await errorSub.cancel();
    }
  }
  throw Exception('所有音轨地址都失败：$lastErr');
}

/// 把 Referer/UA 显式写给 libmpv。
///
/// 为什么需要：media_kit 只在打开主媒体时把 Media.httpHeaders 设成 mpv 的
/// http-header-fields，而 DASH 的外挂音轨走的是 AudioTrack.uri（mpv 的 audio-add），
/// 这条路径拿不到 Media 上的头。B站 的 *.bilivideo.com 对没有 Referer 的请求直接 403，
/// 结果就是音轨加载失败（画面有、声音没有，甚至整个播放被拖死）。
Future<void> applyMediaHeaders(Player player) async {
  final platform = player.platform;
  if (platform is! NativePlayer) return;
  try {
    await platform.setProperty('http-header-fields', kMpvHeaderFields);
  } catch (e) {
    // 设置失败不该影响播放，退化成 media_kit 自己的 Media.httpHeaders
    debugPrint('设置 http-header-fields 失败：$e');
  }
}

/// 把缓存与网络超时参数写给 libmpv（只对原生后端有效）。
Future<void> applyCacheConfig(Player player) async {
  final platform = player.platform;
  if (platform is! NativePlayer) return;
  for (final e in kMpvCacheProps.entries) {
    try {
      await platform.setProperty(e.key, e.value);
    } catch (err) {
      debugPrint('设置 ${e.key} 失败：$err');
    }
  }
}

class BiliAudioHandler extends BaseAudioHandler with SeekHandler {
  BiliAudioHandler(this.player) {
    // 把 media_kit 的状态变化同步给系统（通知栏、锁屏、蓝牙耳机按键都靠它）
    player.stream.playing.listen((playing) => _push());
    // position 事件很密（毫秒级），1 秒节流一次就够通知栏刷新
    player.stream.position.listen((_) => _pushThrottled());
    player.stream.duration.listen((_) => _push());
    player.stream.buffering.listen((b) => _push(buffering: b));
    player.stream.buffer.listen((b) {
      _buffered = b;
      _push();
    });
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

  /// demuxer 已缓存到的位置（PlayerStream.buffer），不是总时长
  Duration _buffered = Duration.zero;
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);

  void _pushThrottled() {
    final now = DateTime.now();
    if (now.difference(_lastPush).inSeconds < 1) return;
    _lastPush = now;
    _push();
  }

  /// 打开一个视频。audioUrl 为空则只有视频自带音轨。
  /// 主 URL 失败时依次尝试 videoUrls/audioUrls 里的备选地址。
  Future<void> open({
    required String videoUrl,
    String? audioUrl,
    List<String> videoUrls = const <String>[],
    List<String> audioUrls = const <String>[],
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
    await applyCacheConfig(player);
    await openVideoWithFallback(player, mergeUrls(videoUrl, videoUrls), title);
    // DASH 分流：视频轨已在播，这里把音频轨挂上，libmpv 负责同步
    final audios = mergeUrls(audioUrl, audioUrls);
    if (audios.isNotEmpty) await setAudioWithFallback(player, audios);
    _push();
  }

  void _push({bool? buffering}) {
    final playing = player.state.playing;
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
      updatePosition: player.state.position,
      // 真实缓存位置；以前这里填的是 duration，进度条会把「已播完」当「已缓存完」
      bufferedPosition: _buffered,
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
