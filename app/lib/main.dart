import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'api.dart';
import 'pages.dart';
import 'player.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();          // 播放器初始化，必须在 runApp 之前

  final saved = await loadCookies();
  final state = AppState(BiliApi(cookies: saved));
  await initPlayer();                    // 建后台播放服务（前台服务 + MediaSession）

  runApp(BiliApp(state: state));
  state.refreshMe();
}
