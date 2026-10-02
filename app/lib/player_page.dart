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

  @override
  void dispose() {
    biliPlayer.pause();
    super.dispose();
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
              child: Video(controller: biliVideoController),
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

/// 简单的播放控制条：进度可拖，播放/暂停，显示时间。
/// 详情页内嵌播放器与独立播放页共用它，控制逻辑只写一份。
/// 传入 [qualities] 时右侧多一个紧凑的清晰度下拉，切换不走独立页面。
class PlayerBar extends StatefulWidget {
  const PlayerBar({
    super.key,
    required this.player,
    this.qualities = const <QualityOption>[],
    this.currentQ,
    this.onPickQuality,
  });
  final Player player;
  final List<QualityOption> qualities;
  final int? currentQ;
  final ValueChanged<QualityOption>? onPickQuality;

  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> {
  double? _dragValue;

  String? get _currentLabel {
    for (final o in widget.qualities) {
      if (o.q == widget.currentQ) return o.label;
    }
    return widget.qualities.isEmpty ? null : widget.qualities.first.label;
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
            final liveValue = max <= 0
                ? 0.0
                : pos.inMilliseconds.toDouble().clamp(0.0, max).toDouble();
            final value = (_dragValue ?? liveValue)
                .clamp(0.0, max <= 0 ? 1.0 : max)
                .toDouble();
            return Column(
              children: [
                Slider(
                  value: value,
                  max: max <= 0 ? 1 : max,
                  onChangeStart: max <= 0 ? null : (v) => setState(() => _dragValue = v),
                  onChanged: max <= 0 ? null : (v) => setState(() => _dragValue = v),
                  onChangeEnd: max <= 0
                      ? null
                      : (v) {
                          setState(() => _dragValue = null);
                          widget.player.seek(Duration(milliseconds: v.round()));
                        },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      StreamBuilder<bool>(
                        stream: widget.player.stream.playing,
                        initialData: widget.player.state.playing,
                        builder: (context, playingSnap) {
                          final playing = playingSnap.data ?? false;
                          return IconButton(
                            icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                            tooltip: playing ? '暂停' : '播放',
                            onPressed: () => playing
                                ? widget.player.pause()
                                : widget.player.play(),
                          );
                        },
                      ),
                      StreamBuilder<bool>(
                        stream: widget.player.stream.buffering,
                        initialData: widget.player.state.buffering,
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
                      if (widget.qualities.isNotEmpty && widget.onPickQuality != null)
                        PopupMenuButton<QualityOption>(
                          tooltip: '清晰度',
                          onSelected: widget.onPickQuality,
                          itemBuilder: (ctx) => widget.qualities
                              .map((o) => PopupMenuItem<QualityOption>(
                                    value: o,
                                    child: Text(o.muxed
                                        ? '${o.label}（单文件）'
                                        : '${o.label}　${o.height ?? '-'}P'),
                                  ))
                              .toList(),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(_currentLabel ?? '清晰度',
                                    style: Theme.of(context).textTheme.bodySmall),
                                const Icon(Icons.arrow_drop_down, size: 20),
                              ],
                            ),
                          ),
                        ),
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
