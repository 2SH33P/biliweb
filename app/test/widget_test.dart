// 只测纯函数，不碰网络。CI 里 flutter create 不会覆盖已存在的文件，
// 所以这里必须自己放一个，否则模板生成的默认测试会引用不存在的 MyApp。
import 'package:biliweb/api.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
