/// 连接真实服务端的同步测试，用两个本地数据库模拟两台设备。
///
///   DEVVAULT_TEST_SERVER=http://127.0.0.1:8080 flutter test test/sync_integration_test.dart
///
/// 未设置环境变量时跳过。会在服务器上注册一个随机账号。
library;

import 'dart:io';
import 'dart:math';

import 'package:devvault_mobile/core/cloud.dart';
import 'package:devvault_mobile/core/db.dart';
import 'package:devvault_mobile/core/models.dart';
import 'package:devvault_mobile/core/repo.dart';
import 'package:devvault_mobile/core/sync.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

final server = Platform.environment['DEVVAULT_TEST_SERVER'];

void main() {
  late Directory dir;
  final user = 'mobile_test_${Random().nextInt(1 << 30)}';
  const password = 'mobile-test-password';

  setUpAll(() {
    setUpTestDb();
    dir = Directory.systemTemp.createTempSync('devvault_sync_');
  });
  tearDownAll(() {
    Db.close();
    dir.deleteSync(recursive: true);
  });

  /// 切换到某台设备（各自独立的数据库文件，登录状态保存在各自的 settings 表中）
  void device(String name) => Db.open('${dir.path}/$name.db');

  Future<SyncStatus> sync() async {
    late SyncStatus last;
    final engine = SyncEngine(onStatus: (s) => last = s, onRemoteChange: () {});
    await engine.syncNow();
    expect(last.error, isNull, reason: '同步失败：${last.error}');
    expect(last.pending, 0);
    expect(last.lastSyncAt, isNotNull, reason: '同步完成后应记录时间');
    return last;
  }

  int idByTitle(String table, String title) => Db.value('SELECT id FROM $table WHERE title = ?', [title]) as int;

  test('两台设备之间的完整同步流程', () async {
    // ---- 设备 A：注册并上传 ----
    device('a');
    await Cloud.register(server!, user, password, name: '手机测试');
    final pid = saveProject(name: '商城', color: '#16a37b');
    saveEntry(Entry(
      projectId: pid,
      title: '管理员账号',
      username: 'admin',
      password: 'p@ss',
      totp: 'JBSWY3DPEHPK3PXP',
      extra: [ExtraField(key: '支付密码', value: '123456', secret: true)],
    ));
    final parent = createTodo(title: '发布 1.0', projectId: pid, dueDate: '2026-11-01');
    createTodo(title: '写更新日志', parentId: parent);
    addComment(parent, '已提测');
    await sync();

    // ---- 设备 B：登录后拉取 ----
    device('b');
    await Cloud.login(server!, user, password);
    await sync();
    final e = listEntries(const AllScope()).single;
    expect(e.password, 'p@ss');
    expect(e.totp, 'JBSWY3DPEHPK3PXP');
    expect(e.extra.single.value, '123456');
    expect(e.projectName, '商城');
    final t = listTodos(const AllScope()).single;
    expect(t.title, '发布 1.0');
    expect(t.projectName, '商城');
    expect(t.subtaskTotal, 1);
    expect(listComments(t.id).single.content, '已提测');
    // 内置优先级使用固定 uid，不会重复
    expect(Db.value('SELECT COUNT(*) FROM priorities'), 4);
    expect(Db.value('SELECT COUNT(*) FROM statuses'), 4);

    // ---- B 修改，A 拉取 ----
    saveEntry(e..title = '超级管理员');
    deleteComment(listComments(t.id).single.id);
    toggleTodo(listSubtasks(t.id).single.id);
    await sync();

    device('a');
    await sync();
    expect(listEntries(const AllScope()).single.title, '超级管理员');
    expect(listComments(parent), isEmpty);
    expect(listSubtasks(parent).single.done, isTrue);

    // ---- 冲突：两端同时修改同一条待办，后修改的一方胜出 ----
    patchTodo(parent, title: 'A 的标题');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    device('b');
    patchTodo(idByTitle('todos', '发布 1.0'), title: 'B 的标题');
    device('a');
    await sync(); // A 先推送
    device('b');
    await sync(); // B 修改更晚：保留 B 的内容并覆盖云端
    expect(getTodo(idByTitle('todos', 'B 的标题')), isNotNull);
    device('a');
    await sync();
    expect(getTodo(parent)!.title, 'B 的标题');

    // ---- 删除与修改冲突：删除优先 ----
    final doomed = createTodo(title: '临时任务');
    await sync();
    device('b');
    await sync();
    final doomedB = idByTitle('todos', '临时任务');
    deleteTodo(doomedB);
    device('a');
    patchTodo(doomed, notes: 'A 在删除后修改');
    device('b');
    await sync(); // B 推送删除
    device('a');
    await sync(); // A 的修改被丢弃，删除生效
    expect(getTodo(doomed), isNull);

    // ---- 退出登录后不再同步 ----
    await Cloud.logout();
    expect(Cloud.loggedIn, isFalse);
  }, skip: server == null ? '未设置 DEVVAULT_TEST_SERVER' : null, timeout: const Timeout(Duration(minutes: 2)));
}
