/// 真机端到端测试：登录 → 同步 → 查看桌面端上传的账号 → 勾选待办。
///
///   adb reverse tcp:18080 tcp:18080
///   flutter test integration_test/sync_flow_test.dart -d <设备> \
///     --dart-define=SERVER=http://127.0.0.1:18080 --dart-define=USER=xxx --dart-define=PASSWORD=xxx
///
/// 账号需事先在服务器上存在，并已由桌面端上传一条名为「桌面端的 GitLab」的账号和「桌面端的待办」。
library;

import 'package:devvault_mobile/app_state.dart' as state;
import 'package:devvault_mobile/core/cloud.dart';
import 'package:devvault_mobile/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const server = String.fromEnvironment('SERVER');
const user = String.fromEnvironment('USER');
const password = String.fromEnvironment('PASSWORD');

Future<void> waitFor(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 300));
    if (finder.evaluate().isNotEmpty) return;
  }
  final st = state.app.syncStatus;
  fail('等待超时：$finder（同步中=${st.syncing}，错误=${st.error}，待上传=${st.pending}）');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('登录并同步桌面端数据', (tester) async {
    await app.main();
    await tester.pumpAndSettle();
    if (Cloud.loggedIn) await Cloud.logout();

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('登录 / 注册'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), server);
    await tester.enterText(fields.at(1), user);
    await tester.enterText(fields.at(2), password);
    await tester.tap(find.widgetWithText(FilledButton, '登录'));

    // 派生密钥 + 登录 + 首次同步
    await waitFor(tester, find.text('立即同步'));
    await waitFor(tester, find.textContaining('上次同步'));

    await tester.tap(find.text('账号'));
    await tester.pumpAndSettle();
    expect(find.text('桌面端的 GitLab'), findsOneWidget);

    await tester.tap(find.text('桌面端的 GitLab'));
    await tester.pumpAndSettle();
    expect(find.text('glpat-xyz'), findsNothing); // 敏感字段默认隐藏
    expect(find.text('https://gitlab.example.com'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('待办'));
    await tester.pumpAndSettle();
    expect(find.text('桌面端的待办'), findsOneWidget);
  });
}
