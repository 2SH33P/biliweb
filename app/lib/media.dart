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
    this.width, this.height, this.fps, List<String>? urls})
      : urls = urls ?? (url.isEmpty ? const <String>[] : <String>[url]);
  final String url;
  /// 候选地址（base + backup），按可用顺序排列，首个通常就是 [url]。
  /// B站 的 DASH 分片会给多路 CDN，主路 403/超时就该顺延试下一路。
  final List<String> urls;
  final int bandwidth;
  final String codecs;
  final int? width;
  final int? height;
  final int? fps;
}

/// 从 DASH 节点收集所有可用音轨候选。
///
/// `dash.audio` 为空时兼容 `dash.dolby.audio` 与 `dash.flac.audio`
/// （B站 对部分视频只下发杜比/无损音轨），后两者既可能是单个对象也可能是数组。
List<Map<String, dynamic>> dashAudioPool(Map<String, dynamic>? dash) {
  if (dash == null) return const <Map<String, dynamic>>[];
  final normal = (dash['audio'] as List? ?? const [])
      .cast<Map<String, dynamic>>()
      .where((audio) => trackUrls(audio).isNotEmpty)
      .toList();
  if (normal.isNotEmpty) return normal;
  final out = <Map<String, dynamic>>[];
  for (final key in const ['dolby', 'flac']) {
    final node = dash[key];
    final a = node is Map ? node['audio'] : null;
    if (a is Map) {
      out.add(a.cast<String, dynamic>());
    } else if (a is List) {
      out.addAll(a.cast<Map<String, dynamic>>());
    }
  }
  return out;
}

/// 音轨池挑选：优先 mp4a（兼容性最好），没有则用整池；过滤掉没有可用 URL 的项。
/// 不再「仅挑 mp4a」，否则杜比/无损音轨的视频会直接静音。
List<Map<String, dynamic>> pickAudioCandidates(Map<String, dynamic>? dash) {
  final usable = dashAudioPool(dash).where((a) => trackUrls(a).isNotEmpty).toList();
  if (usable.isEmpty) return const <Map<String, dynamic>>[];
  final mp4a = usable
      .where((a) => (a['codecs'] ?? '').toString().startsWith('mp4a'))
      .toList();
  return mp4a.isNotEmpty ? mp4a : usable;
}

/// 抽出一个轨道的所有候选 URL：base_url/baseUrl + backup_url/backupUrl，去重保序。
List<String> trackUrls(Map<String, dynamic> x) {
  final out = <String>[];
  void add(dynamic v) {
    final s = (v ?? '').toString().trim();
    if (s.isNotEmpty && !out.contains(s)) out.add(s);
  }

  add(x['base_url'] ?? x['baseUrl']);
  for (final key in const ['backup_url', 'backupUrl']) {
    final b = x[key];
    if (b is List) {
      for (final u in b) {
        add(u);
      }
    } else {
      add(b);
    }
  }
  return out;
}

/// 合并主 URL 与候选列表，去重并保持顺序（主 URL 在前）。
List<String> mergeUrls(String? primary, List<String> candidates) {
  final out = <String>[];
  for (final u in <String>[if (primary != null) primary, ...candidates]) {
    final s = u.trim();
    if (s.isNotEmpty && !out.contains(s)) out.add(s);
  }
  return out;
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
    // 音轨池：audio 为空时回退 dolby/flac；不再仅挑 mp4a（否则杜比/无损视频静音）
    final audioPool = pickAudioCandidates(dashData);
    MediaTrack? bestAudio;
    if (audioPool.isNotEmpty) {
      final a = audioPool.reduce((x, y) =>
          ((x['bandwidth'] as int?) ?? 0) >= ((y['bandwidth'] as int?) ?? 0) ? x : y);
      final urls = trackUrls(a);
      bestAudio = MediaTrack(
        url: urls.isEmpty ? '' : urls.first,
        urls: urls,
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
      final vurls = trackUrls(x);
      options[q] = QualityOption(
        q: q,
        label: kQuality[q] ?? '$q',
        kind: 'dash',
        bytes: ((vbr + abr) / 8 * duration).round(),
        video: MediaTrack(
          url: vurls.isEmpty ? '' : vurls.first,
          urls: vurls,
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
            urls: trackUrls({'base_url': durls.first['url'],
              'backup_url': durls.first['backup_url'] ?? durls.first['backupUrl']}),
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
