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
  bool _started = false;
  int? _q;

  @override
  void initState() {
    super.initState();
    _q = widget.initialQ;
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    _started = true;
  }

  bool get _isLocal =>
      widget.localVideoPath != null || widget.videoUrl.startsWith('file:');

  Future<void> _play(QualityOption? o) async {
    final video = widget.localVideoPath != null
        ? Uri.file(widget.localVideoPath!).toString()
        : (o?.video?.url ?? widget.videoUrl);
    final audio = widget.localAudioPath != null
        ? Uri.file(widget.localAudioPath!).toString()
        : (o == null ? widget.audioUrl : (o.muxed ? null : o.audio?.url));
    try {
      await openMedia(
        videoUrl: video,
        audioUrl: audio,
        title: widget.title,
        artist: widget.artist,
        artUri: widget.artUri,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('播放失败：$e')));
      }
    }
  }

  Future<void> _start() async {
    if (!_started) return;
    final info = widget.info;
    if (info != null && _q == null && info.qualities.isNotEmpty) {
      _q = info.qualities.first.q;
    }
    final chosen = info?.qualities.where((o) => o.q == _q).toList();
    await _play(chosen == null || chosen.isEmpty ? null : chosen.first);
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
              child: Video(controller: VideoController(biliPlayer)),
            ),
          ),
          PlayerBar(player: biliPlayer),
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
                        onTap: _isLocal
                            ? null
                            : () async {
                                setState(() => _q = o.q);
                                await _play(o);
                              },
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

/// 简单的播放控制条：进度可拖，播放/暂停，显示时间
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key, required this.player});
  final Player player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, posSnap) {
        final pos = posSnap.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: player.stream.duration,
          initialData: player.state.duration,
          builder: (context, durSnap) {
            final dur = durSnap.data ?? Duration.zero;
            final max = dur.inMilliseconds.toDouble();
            final value = max <= 0
                ? 0.0
                : pos.inMilliseconds.toDouble().clamp(0.0, max).toDouble();
            return Column(
              children: [
                Slider(
                  value: value,
                  max: max <= 0 ? 1 : max,
                  onChanged: max <= 0
                      ? null
                      : (v) => player.seek(Duration(milliseconds: v.round())),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      StreamBuilder<bool>(
                        stream: player.stream.playing,
                        initialData: player.state.playing,
                        builder: (context, playingSnap) {
                          final playing = playingSnap.data ?? false;
                          return IconButton(
                            icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                            tooltip: playing ? '暂停' : '播放',
                            onPressed: () => playing ? player.pause() : player.play(),
                          );
                        },
                      ),
                      StreamBuilder<bool>(
                        stream: player.stream.buffering,
                        initialData: player.state.buffering,
                        builder: (context, bufSnap) =>
                            (bufSnap.data ?? false)
                                ? const Padding(
                                    padding: EdgeInsets.only(left: 8),
                                    child: SizedBox(
                                      width: 14, height: 14,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                      ),
                      const Spacer(),
                      Text('${_fmt(pos)} / ${_fmt(dur)}',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
