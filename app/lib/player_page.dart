import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'media.dart';
import 'player.dart';

/// 播放页：视频画面 + 控制条 + 清晰度切换。
/// 退到后台/锁屏由 audio_service 接管，继续放。
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.title,
    this.videoUrl = '',
    this.audioUrl,
    this.localVideoPath,
    this.localAudioPath,
    this.artist = '',
    this.artUri,
    this.info,
    this.initialQ,
  });

  final String title;
  final String videoUrl;
  final String? audioUrl;
  final String? localVideoPath;
  final String? localAudioPath;
  final String artist;
  final String? artUri;

  /// 有 MediaInfo 时显示清晰度列表
  final MediaInfo? info;
  final int? initialQ;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  int? _q;
  bool _switchingQuality = false;

  @override
  void initState() {
    super.initState();
    _q = widget.initialQ;
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  bool get _isLocal =>
      widget.localVideoPath != null || widget.videoUrl.startsWith('file:');

  QualityOption? _find(int? q) {
    final info = widget.info;
    if (info == null || q == null) return null;
    for (final o in info.qualities) {
      if (o.q == q) return o;
    }
    return null;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 返回是否成功打开；调用方据此决定要不要回滚清晰度。
  Future<bool> _play(QualityOption? o, {required Duration resumeAt}) async {
    final localVideo = widget.localVideoPath != null;
    final video = localVideo
        ? Uri.file(widget.localVideoPath!).toString()
        : (o?.video?.url ?? widget.videoUrl);
    // 空 URL 不交给 libmpv（会打开一个空 Media，画面/状态全错）。
    if (video.isEmpty) {
      _snack('没有可用的播放地址');
      return false;
    }
    final localAudio = widget.localAudioPath != null;
    final audio = localAudio
        ? Uri.file(widget.localAudioPath!).toString()
        : (o == null ? widget.audioUrl : (o.muxed ? null : o.audio?.url));
    // 网络视频带上 backup 候选，主 CDN 失败时回退
    final videoUrls = localVideo ? const <String>[] : (o?.video?.urls ?? const <String>[]);
    final audioUrls = (localAudio || o == null || o.muxed)
        ? const <String>[]
        : (o.audio?.urls ?? const <String>[]);
    try {
      await openMedia(
        videoUrl: video,
        audioUrl: audio,
        videoUrls: videoUrls,
        audioUrls: audioUrls,
        title: widget.title,
        artist: widget.artist,
        artUri: widget.artUri,
      );
      if (resumeAt > Duration.zero) await biliPlayer.seek(resumeAt);
      return true;
    } catch (e) {
      _snack('播放失败：$e');
      return false;
    }
  }

  Future<void> _start() async {
    if (!mounted) return;
    final info = widget.info;
    if (info != null) {
      if (info.qualities.isEmpty) {
        // 无清晰度：报错，不去开空 Media
        _snack('没有可用的清晰度');
        return;
      }
      _q ??= pickDefaultQuality(info.qualities)?.q;
    } else if (widget.videoUrl.isEmpty && widget.localVideoPath == null) {
      _snack('没有可用的播放地址');
      return;
    }
    await _play(_find(_q), resumeAt: Duration.zero);
  }

  /// 切清晰度：失败则回滚到旧清晰度，并把旧流重新放回去。
  Future<void> _switchQuality(QualityOption o) async {
    if (_switchingQuality || o.q == _q) return;
    final resumeAt = biliPlayer.state.position;
    final oldQ = _q;
    final old = _find(oldQ);
    setState(() {
      _switchingQuality = true;
      _q = o.q;
    });
    final ok = await _play(o, resumeAt: resumeAt);
    if (!ok && mounted) {
      setState(() => _q = oldQ);
      if (old != null) await _play(old, resumeAt: resumeAt);
    }
    if (mounted) setState(() => _switchingQuality = false);
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Column(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ColoredBox(
              color: Colors.black,
              child: Video(
                controller: biliVideoController,
                controls: (state) => BiliVideoControls(
                  state: state,
                  player: biliPlayer,
                  shots: info?.shots,
                  qualities: info?.qualities ?? const <QualityOption>[],
                  currentQ: _q,
                  onPickQuality: _switchingQuality ? null : _switchQuality,
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('后台播放', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                Text(
                  '退到后台或锁屏会继续播放，通知栏与锁屏上有播放控制。'
                  '安卓 13 及以上若看不到通知，去系统设置里给本应用打开通知权限。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (info != null && info.qualities.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text('清晰度', style: Theme.of(context).textTheme.titleSmall),
                  ...info.qualities.map((o) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text('${o.label}　${o.muxed ? '单文件' : 'DASH 分流'}'),
                        subtitle: Text(
                            '${o.width ?? '-'}×${o.height ?? '-'} · ${o.codecs} · 约 ${mbText(o.bytes)}'),
                        trailing: o.q == _q ? const Icon(Icons.check) : null,
                        onTap: (_isLocal || _switchingQuality)
                            ? null
                            : () => _switchQuality(o),
                      )),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String mbText(int b) =>
    b <= 0 ? '未知大小' : '${(b / 1048576).toStringAsFixed(0)} MB';

class BiliVideoControls extends StatelessWidget {
  const BiliVideoControls({
    super.key, required this.state, required this.player, this.shots,
    this.qualities = const <QualityOption>[], this.currentQ, this.onPickQuality,
  });
  final VideoState state;
  final Player player;
  final VideoShotInfo? shots;
  final List<QualityOption> qualities;
  final int? currentQ;
  final ValueChanged<QualityOption>? onPickQuality;

  @override
  Widget build(BuildContext context) {
    final fullscreen = state.isFullscreen();
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        top: false,
        child: Container(
          color: Colors.black.withValues(alpha: .72),
          child: Theme(
            data: ThemeData.dark(useMaterial3: true),
            child: PlayerBar(
              player: player, shots: shots, qualities: qualities,
              currentQ: currentQ, onPickQuality: onPickQuality,
              onFullscreen: () => fullscreen
                  ? state.exitFullscreen()
                  : state.enterFullscreen(),
            ),
          ),
        ),
      ),
    );
  }
}

/// 页内与全屏共用的控制条：拖动预览、倍速、0–200% 音量和清晰度。
class PlayerBar extends StatefulWidget {
  const PlayerBar({
    super.key, required this.player, this.shots, this.onFullscreen,
    this.qualities = const <QualityOption>[], this.currentQ, this.onPickQuality,
  });
  final Player player;
  final VideoShotInfo? shots;
  final VoidCallback? onFullscreen;
  final List<QualityOption> qualities;
  final int? currentQ;
  final ValueChanged<QualityOption>? onPickQuality;

  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> {
  static const _speeds = <double>[.5, .75, 1, 1.25, 1.5, 2, 3, 5, 10];
  double? _dragValue;

  String? get _currentLabel {
    for (final o in widget.qualities) {
      if (o.q == widget.currentQ) return o.label;
    }
    return widget.qualities.isEmpty ? null : widget.qualities.first.label;
  }

  Future<void> _volumeSheet() async {
    var volume = widget.player.state.volume.clamp(0, 200).toDouble();
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('音量 ${volume.round()}%'),
              Slider(
                value: volume, max: 200, divisions: 40,
                onChanged: (v) {
                  setSheetState(() => volume = v);
                  widget.player.setVolume(v);
                },
              ),
              const Text('100% 以上会放大音频，可能出现失真'),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _shotPreview(double milliseconds) {
    final shots = widget.shots;
    final frame = shots?.frameAt(Duration(milliseconds: milliseconds.round()));
    if (shots == null || frame == null) return const SizedBox.shrink();
    const targetWidth = 160.0;
    final scale = targetWidth / shots.width;
    final targetHeight = shots.height * scale;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: targetWidth, height: targetHeight,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: shots.width * shots.columns * scale,
              maxWidth: shots.width * shots.columns * scale,
              minHeight: shots.height * shots.rows * scale,
              maxHeight: shots.height * shots.rows * scale,
              child: Transform.translate(
                offset: Offset(-frame.column * targetWidth, -frame.row * targetHeight),
                child: Image.network(
                  frame.url,
                  width: shots.width * shots.columns * scale,
                  height: shots.height * shots.rows * scale,
                  fit: BoxFit.fill,
                  errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text(_fmt(Duration(milliseconds: milliseconds.round()))),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.player.stream.position,
      initialData: widget.player.state.position,
      builder: (context, posSnap) {
        final pos = posSnap.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: widget.player.stream.duration,
          initialData: widget.player.state.duration,
          builder: (context, durSnap) {
            final dur = durSnap.data ?? Duration.zero;
            final max = dur.inMilliseconds.toDouble();
            final live = max <= 0 ? 0.0
                : pos.inMilliseconds.toDouble().clamp(0.0, max).toDouble();
            final value = (_dragValue ?? live).clamp(0.0, max <= 0 ? 1.0 : max).toDouble();
            return Column(children: [
              if (_dragValue != null) _shotPreview(_dragValue!),
              Slider(
                value: value, max: max <= 0 ? 1 : max,
                onChangeStart: max <= 0 ? null : (v) => setState(() => _dragValue = v),
                onChanged: max <= 0 ? null : (v) => setState(() => _dragValue = v),
                onChangeEnd: max <= 0 ? null : (v) {
                  setState(() => _dragValue = null);
                  widget.player.seek(Duration(milliseconds: v.round()));
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(children: [
                  StreamBuilder<bool>(
                    stream: widget.player.stream.playing,
                    initialData: widget.player.state.playing,
                    builder: (context, snap) {
                      final playing = snap.data ?? false;
                      return IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                        onPressed: () => playing ? widget.player.pause() : widget.player.play(),
                      );
                    },
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '停止', icon: const Icon(Icons.stop),
                    onPressed: widget.player.stop,
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '音量', icon: const Icon(Icons.volume_up),
                    onPressed: _volumeSheet,
                  ),
                  StreamBuilder<double>(
                    stream: widget.player.stream.rate,
                    initialData: widget.player.state.rate,
                    builder: (context, snap) {
                      final rate = snap.data ?? 1;
                      return PopupMenuButton<double>(
                        tooltip: '倍速',
                        onSelected: widget.player.setRate,
                        itemBuilder: (_) => _speeds.map((x) => PopupMenuItem(
                          value: x, child: Text('${_rateText(x)}×'),
                        )).toList(),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          child: Text('${_rateText(rate)}×'),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '全屏', icon: const Icon(Icons.fullscreen),
                    onPressed: widget.onFullscreen,
                  ),
                  const Spacer(),
                  if (widget.qualities.isNotEmpty && widget.onPickQuality != null)
                    PopupMenuButton<QualityOption>(
                      tooltip: '清晰度', onSelected: widget.onPickQuality,
                      itemBuilder: (_) => widget.qualities.map((o) => PopupMenuItem(
                        value: o, child: Text(o.muxed ? '${o.label}（单文件）' : o.label),
                      )).toList(),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        child: Text(_currentLabel ?? '清晰度'),
                      ),
                    ),
                  Text('${_fmt(_dragValue == null ? pos : Duration(milliseconds: _dragValue!.round()))} / ${_fmt(dur)}',
                      style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
            ]);
          },
        );
      },
    );
  }

  static String _rateText(double value) =>
      value.toString().replaceFirst(RegExp(r'\.0$'), '');

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
