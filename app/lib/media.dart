// 清晰度与下载。全部走客户端自己的 IP，不经过任何中转服务器。
//
// 两个要点：
//  1. CDN 的 Referer 白名单：*.bilivideo.com 要求 Referer 正好是 bilibili.com，
//     浏览器做不到（网页版因此放弃了直连），但原生请求头想设就设，所以这里能直连。
//  2. 下载分两种：B站自己合好的单文件流（通用 mp4，清晰度上限较低）
//     和 DASH 分流（高清，但视频/音频是两个文件，得一起下载）。
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'api.dart';

/// 下载用到的请求头。Referer 不能少，否则部分 CDN 直接 403。
const Map<String, String> kMediaHeaders = {
  'Referer': 'https://www.bilibili.com/',
  'User-Agent': kUserAgent,
};

/// libmpv 的 http-header-fields 格式（逗号分隔的 `Header: value`）。
/// DASH 的外挂音轨是 libmpv 自己去拉的，不继承 Media.httpHeaders，必须单独设，
/// 否则 *.bilivideo.com 的音轨会 403（画面能放、没声音）。
const String kMpvHeaderFields =
    'Referer: https://www.bilibili.com/,User-Agent: $kUserAgent';

/// H.264 兼容性最好，手机上 hvc1/av01 经常放不出来
const List<String> _codecRank = ['avc1', 'hvc1', 'hev1', 'av01'];

class MediaTrack {
  MediaTrack({required this.url, required this.bandwidth, required this.codecs,
    this.width, this.height, this.fps});
  final String url;
  final int bandwidth;
  final String codecs;
  final int? width;
  final int? height;
  final int? fps;
}

class QualityOption {
  QualityOption({
    required this.q,
    required this.label,
    required this.kind,
    required this.bytes,
    this.video,
    this.audio,
    required this.muxed,
    this.width,
    this.height,
    this.codecs = '',
    this.fps = 0,
  });

  /// 清晰度 id（127=8K, 120=4K, 116=1080P60, 80=1080P, 64=720P, 32=480P, 16=360P）
  final int q;
  final String label;

  /// 'muxed' = B站合好的单文件；'dash' = 视频音频分开
  final String kind;
  final int bytes;
  final MediaTrack? video;
  final MediaTrack? audio;
  final bool muxed;
  final int? width;
  final int? height;
  final String codecs;
  final int fps;

  bool get isDash => kind == 'dash';
}

class MediaInfo {
  MediaInfo({required this.title, required this.duration, required this.qualities});
  final String title;
  final int duration;
  final List<QualityOption> qualities;
}

/// 编码偏好排序：H.264 兼容性最好，排最前，未知编码垫底。
int _rank(String codecs) {
  final head = codecs.split('.').first;
  final i = _codecRank.indexOf(head);
  return i < 0 ? 9 : i;
}

/// 默认清晰度策略（纯函数，可单测）：
/// 1. 优先 720P（q=64）的 DASH，同档里优先 H.264；
/// 2. 没有则取「不高于 720P」的最高可用；
/// 3. 还没有则取最低可用。绝不默认 4K/8K。
QualityOption? pickDefaultQuality(List<QualityOption> list) {
  if (list.isEmpty) return null;
  final dash720 = list.where((o) => o.q == 64 && o.isDash).toList()
    ..sort((a, b) => _rank(a.codecs).compareTo(_rank(b.codecs)));
  if (dash720.isNotEmpty) return dash720.first;
  final capped = list.where((o) => o.q <= 64).toList()
    ..sort((a, b) => b.q.compareTo(a.q));
  if (capped.isNotEmpty) return capped.first;
  return (list.toList()..sort((a, b) => a.q.compareTo(b.q))).first;
}

/// 把单文件流并入清晰度清单：同 q 已有 DASH 时保留 DASH（码率/编码更好），
/// 单文件只在那一档没有 DASH 时才补进去。
void mergeMuxed(Map<int, QualityOption> options, QualityOption muxed) {
  final existing = options[muxed.q];
  if (existing != null && existing.isDash) return;
  options[muxed.q] = muxed;
}

class BiliMedia {
  BiliMedia(this.api);
  final BiliApi api;

  /// frame_rate 上游给的是字符串（"30.000"），直接 `as num` 会抛 TypeError；
  /// 这个转换在 info() 的主循环里，一抛就是「预览和下载一起失败」。
  static int _fps(dynamic v) {
    if (v == null) return 0;
    final n = v is num ? v : num.tryParse(v.toString());
    return n?.round() ?? 0;
  }

  /// 同时取 DASH 分流与单文件流，合并成一份可选清晰度清单
  Future<MediaInfo> info(String bvid) async {
    final v = (await api.get('${BiliApi.apiBase}/x/web-interface/view', {'bvid': bvid}))['data']
        as Map<String, dynamic>;
    final cid = v['cid'];
    final duration = (v['duration'] as int?) ?? 0;

    final dash = (await api.get(
        '${BiliApi.apiBase}/x/player/wbi/playurl',
        {'bvid': bvid, 'cid': cid, 'qn': 127, 'fnval': 4048, 'fourk': 1},
        wbi: true))['data'] as Map<String, dynamic>? ?? {};

    final muxed = (await api.get(
        '${BiliApi.apiBase}/x/player/wbi/playurl',
        {'bvid': bvid, 'cid': cid, 'qn': 127, 'fnval': 1},
        wbi: true))['data'] as Map<String, dynamic>? ?? {};

    final options = <int, QualityOption>{};

    // DASH：按清晰度分组，每组挑一个最兼容的编码
    final dashData = dash['dash'] as Map<String, dynamic>? ?? {};
    final videos = (dashData['video'] as List? ?? []).cast<Map<String, dynamic>>();
    final audios = (dashData['audio'] as List? ?? []).cast<Map<String, dynamic>>()
        .where((a) => (a['codecs'] ?? '').toString().startsWith('mp4a'))
        .toList();
    final audioPool = audios.isNotEmpty
        ? audios
        : (dashData['audio'] as List? ?? []).cast<Map<String, dynamic>>();
    MediaTrack? bestAudio;
    if (audioPool.isNotEmpty) {
      final a = audioPool.reduce((x, y) =>
          ((x['bandwidth'] as int?) ?? 0) >= ((y['bandwidth'] as int?) ?? 0) ? x : y);
      bestAudio = MediaTrack(
        url: (a['base_url'] ?? a['baseUrl'] ?? '').toString(),
        bandwidth: (a['bandwidth'] as int?) ?? 0,
        codecs: (a['codecs'] ?? '').toString(),
      );
    }
    final byQ = <int, List<Map<String, dynamic>>>{};
    for (final x in videos) {
      final q = x['id'] as int? ?? 0;
      byQ.putIfAbsent(q, () => []).add(x);
    }
    byQ.forEach((q, list) {
      list.sort((a, b) {
        final r = _rank((a['codecs'] ?? '').toString())
            .compareTo(_rank((b['codecs'] ?? '').toString()));
        if (r != 0) return r;
        return ((b['bandwidth'] as int?) ?? 0).compareTo((a['bandwidth'] as int?) ?? 0);
      });
      final x = list.first;
      final vbr = (x['bandwidth'] as int?) ?? 0;
      final abr = bestAudio?.bandwidth ?? 0;
      options[q] = QualityOption(
        q: q,
        label: kQuality[q] ?? '$q',
        kind: 'dash',
        bytes: ((vbr + abr) / 8 * duration).round(),
        video: MediaTrack(
          url: (x['base_url'] ?? x['baseUrl'] ?? '').toString(),
          bandwidth: vbr,
          codecs: (x['codecs'] ?? '').toString(),
          width: x['width'] as int?,
          height: x['height'] as int?,
          fps: _fps(x['frame_rate']),
        ),
        audio: bestAudio,
        muxed: false,
        width: x['width'] as int?,
        height: x['height'] as int?,
        codecs: (x['codecs'] ?? '').toString().split('.').first,
        fps: _fps(x['frame_rate']),
      );
    });

    // 单文件流：B站 已经合好，下一个文件就能看；但同清晰度的 DASH 是更好的源，不能被它覆盖
    final durls = (muxed['durl'] as List? ?? []).cast<Map<String, dynamic>>();
    if (durls.isNotEmpty) {
      final q = (muxed['quality'] as int?) ?? 64;
      final size = (durls.first['size'] as int?) ?? 0;
      mergeMuxed(
        options,
        QualityOption(
          q: q,
          label: kQuality[q] ?? '$q',
          kind: 'muxed',
          bytes: size,
          video: MediaTrack(
            url: (durls.first['url'] ?? '').toString(),
            bandwidth: 0,
            codecs: 'mp4',
          ),
          audio: null,
          muxed: true,
          codecs: 'mp4',
        ),
      );
    }

    final list = options.values.toList()
      ..sort((a, b) => b.q.compareTo(a.q));
    return MediaInfo(
      title: (v['title'] ?? '').toString(),
      duration: duration,
      qualities: list,
    );
  }

  /// 下载一个 URL 到文件，回报 0..1 进度
  Future<File> fetch(String url, String path, {void Function(double)? onProgress,
    bool Function()? isCancelled}) async {
    final req = http.Request('GET', Uri.parse(url));
    req.headers.addAll(kMediaHeaders);
    final res = await http.Client().send(req);
    if (res.statusCode >= 400) {
      throw BiliException(res.statusCode, '下载失败 HTTP ${res.statusCode}');
    }
    final file = File(path);
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    final total = res.contentLength ?? 0;
    var got = 0;
    try {
      await for (final chunk in res.stream) {
        if (isCancelled?.call() == true) {
          throw BiliException(-1, '已取消');
        }
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress?.call(got / total);
      }
    } finally {
      await sink.close();
    }
    onProgress?.call(1);
    return file;
  }

  static String safeName(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]+'), '_').trim();

  static Future<Directory> downloadDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
