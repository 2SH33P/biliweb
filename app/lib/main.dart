import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'pages.dart';
import 'player.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 先把界面画出来：任何初始化都不允许挡首帧。
  // 之前把播放器/后台服务 await 在 runApp 前面，一旦它们卡住或抛异常，
  // 首帧永远画不出来，安卓 12+ 就一直停在图标页。
  Map<String, String>? saved;
  try {
    saved = await loadCookies();
  } catch (_) {
    saved = null;
  }
  final state = AppState(BiliApi(cookies: saved));
  runApp(BiliApp(state: state));

  unawaited(() async {
    // Python 版在构造函数里就会补 buvid3/buvid4；Dart 的构造函数不能 await，放到这里补。
    // 只在登录成功时补一次是不够的：升级上来的用户 cookie 里没有它，
    // space/* 之类的接口会回 -352「风控校验失败」而不是正常数据。
    if ((state.api.cookies['buvid3'] ?? '').isEmpty) {
      await state.api.fetchBuvid();
      if ((state.api.cookies['buvid3'] ?? '').isNotEmpty) {
        await saveCookies(state.api.cookies);
      }
    }
    await state.refreshMe();
  }());

  // 播放器初始化放首帧之后；失败只记到 state 上由界面显示，不影响浏览与下载
  unawaited(() async {
    await initPlayer();
    state.setPlayerStatus(playerInitError.isEmpty
        ? '就绪${audioServiceReady ? '（含后台播放）' : '（无后台服务，仅应用内播放）'}'
        : playerInitError);
  }());
}
