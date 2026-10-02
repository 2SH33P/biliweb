// 只测纯函数，不碰网络。CI 里 flutter create 不会覆盖已存在的文件，
// 所以这里必须自己放一个，否则模板生成的默认测试会引用不存在的 MyApp。
import 'package:biliweb/api.dart';
import 'package:biliweb/media.dart';
import 'package:flutter_test/flutter_test.dart';

QualityOption _opt(int q, String kind, {String codecs = 'avc1'}) => QualityOption(
      q: q,
      label: '$q',
      kind: kind,
      bytes: 0,
      muxed: kind == 'muxed',
      codecs: codecs,
    );

void main() {
  test('fmtCount 按中文习惯分档', () {
    expect(BiliApi.fmtCount(0), '0');
    expect(BiliApi.fmtCount(9999), '9999');
    expect(BiliApi.fmtCount(12345), '1.2万');
    expect(BiliApi.fmtCount(123456789), '1.2亿');
  });

  test('parseTs 支持 epoch 与日期字符串', () {
    expect(BiliApi.parseTs('1758000000', 0), 1758000000);
    expect(BiliApi.parseTs('', 7), 7);
    final t = BiliApi.parseTs('2026-09-01', 0);
    final e = BiliApi.parseTs('2026-09-01', 0, endOfDay: true);
    expect(e - t, 86399);
  });

  test('ago 分档', () {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    expect(BiliApi.ago(now - 120), '2分钟前');
    expect(BiliApi.ago(now - 7200), '2小时前');
    expect(BiliApi.ago(now - 86400 * 3), '3天前');
  });

  test('默认清晰度优先 720P DASH 且优先 H.264', () {
    final list = [
      _opt(127, 'dash'),
      _opt(80, 'dash'),
      _opt(64, 'muxed'),
      _opt(64, 'dash', codecs: 'hev1'),
      _opt(64, 'dash', codecs: 'avc1'),
    ];
    final picked = pickDefaultQuality(list)!;
    expect(picked.q, 64);
    expect(picked.isDash, isTrue);
    expect(picked.codecs, 'avc1');
  });

  test('无 720P 时选不高于 720P 的最高可用', () {
    final picked = pickDefaultQuality([
      _opt(120, 'dash'),
      _opt(80, 'dash'),
      _opt(32, 'dash'),
    ])!;
    expect(picked.q, 80);
  });

  test('仅有超高清档时选择其中最低档', () {
    final picked = pickDefaultQuality([_opt(127, 'dash'), _opt(120, 'dash')])!;
    expect(picked.q, 120);
  });

  test('同清晰度 DASH 不被单文件覆盖', () {
    final options = <int, QualityOption>{64: _opt(64, 'dash')};
    mergeMuxed(options, _opt(64, 'muxed'));
    expect(options[64]!.isDash, isTrue);
    // 没有 DASH 的档位才补单文件
    mergeMuxed(options, _opt(32, 'muxed'));
    expect(options[32]!.kind, 'muxed');
  });
}

// 启动路径的自检：initPlayer 无论成败都不能抛异常，
// 否则 main() 会在 runApp 之前挂掉，首帧永远画不出来（曾卡在图标页）。
