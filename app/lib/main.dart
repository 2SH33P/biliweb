import 'package:flutter/material.dart';

import 'api.dart';
import 'pages.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final saved = await loadCookies();
  final state = AppState(BiliApi(cookies: saved));
  runApp(BiliApp(state: state));
  // 启动后补一次登录状态，失败也不影响浏览
  state.refreshMe();
}
