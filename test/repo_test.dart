import 'package:devvault_mobile/core/db.dart';
import 'package:devvault_mobile/core/models.dart';
import 'package:devvault_mobile/core/repo.dart';
import 'package:devvault_mobile/core/totp.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  setUp(setUpTestDb);

  test('迁移结果与桌面端一致：内置优先级 / 状态使用固定 uid', () {
    expect(Db.raw.userVersion, 7);
    expect(Db.all('SELECT uid FROM priorities ORDER BY id').map((r) => r['uid']), ['priority-1', 'priority-2', 'priority-3', 'priority-4']);
    expect(Db.all('SELECT uid FROM statuses ORDER BY id').map((r) => r['uid']), ['status-1', 'status-2', 'status-3', 'status-4']);
  });

  test('账号增删改，敏感字段本机加密存储', () {
    final pid = saveProject(name: '商城', color: '#3b6cff');
    final id = saveEntry(Entry(
      projectId: pid,
      title: '管理员',
      username: 'admin',
      password: 'secret!',
      totp: 'JBSWY3DPEHPK3PXP',
      tags: 'a, b，a',
      extra: [ExtraField(key: '支付密码', value: '666', secret: true), ExtraField(key: '手机号', value: '138')],
    ));
    final raw = Db.get('SELECT password, totp, extra, tags, sync_dirty, uid FROM entries WHERE id = ?', [id])!;
    expect(raw['password'], startsWith('lk1:'));
    expect(raw['extra'], isNot(contains('666')));
    expect(raw['tags'], 'a,b');
    expect(raw['sync_dirty'], 1);
    expect(raw['uid'], isNotNull);

    final e = getEntry(id)!;
    expect(e.password, 'secret!');
    expect(e.totp, 'JBSWY3DPEHPK3PXP');
    expect(e.extra.first.value, '666');
    expect(e.projectName, '商城');
    expect(listEntries(const AllScope(), keyword: '管理 商城').length, 1);
    expect(listEntries(const AllScope(), keyword: '不存在').length, 0);
    expect(listEntries(const NoneScope()).length, 0);

    Db.run('UPDATE entries SET sync_rev = 3, sync_dirty = 0');
    deleteEntry(id);
    expect(Db.all('SELECT kind, rev FROM sync_tombstones WHERE kind = ?', ['entry']), [
      {'kind': 'entry', 'rev': 3},
    ]);
  });

  test('待办：勾选完成、子任务、重复任务生成下一次', () {
    final id = createTodo(title: '周报', dueDate: '2026-10-16', repeat: 'weekly', remindAt: '2026-10-16T09:30');
    createTodo(title: '收集数据', parentId: id);
    expect(listTodos(const AllScope(), done: false).single.subtaskTotal, 1);

    toggleTodo(id);
    final done = getTodo(id)!;
    expect(done.done, isTrue);
    expect(done.statusKind, 'done');
    expect(done.repeat, '');

    final next = listTodos(const AllScope(), done: false).single;
    expect(next.title, '周报');
    expect(next.repeat, 'weekly');
    expect(next.dueDate.compareTo(today()) >= 0, isTrue);
    expect(next.remindAt, '${next.dueDate}T09:30');
    expect(listSubtasks(next.id).single.title, '收集数据');

    patchTodo(next.id, statusId: 2, title: '周报（新）');
    expect(getTodo(next.id)!.statusName, '进行中');
    expect(getTodo(next.id)!.done, isFalse);

    addComment(next.id, '进展 1');
    expect(listComments(next.id).single.content, '进展 1');
    // 仍有未完成子任务的已完成任务不会被清理
    expect(clearDoneTodos(const AllScope()), 0);
    toggleTodo(listSubtasks(id).single.id);
    expect(clearDoneTodos(const AllScope()), 1);
    expect(getTodo(id), isNull);
  });

  test('重复日期推进与桌面端一致', () {
    expect(nextDueDate('2026-01-31', 'monthly', '2026-01-01'), '2026-02-28');
    expect(nextDueDate('2026-10-16', 'weekdays', '2026-10-01'), '2026-10-19');
    expect(nextDueDate('', 'daily', '2026-10-17'), '2026-10-18');
    expect(nextDueDate('2026-01-01', 'weekly', '2026-01-20'), '2026-01-22');
  });

  test('TOTP 与 RFC 6238 测试向量一致', () {
    // RFC 6238 附录 B：密钥 "12345678901234567890"，T=59s → 94287082（8 位，SHA1）
    final cfg = parseTotp('otpauth://totp/ACME:alice?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8&issuer=ACME')!;
    expect(cfg.account, 'alice');
    expect(totpCode(cfg, DateTime.fromMillisecondsSinceEpoch(59000)), '94287082');
    expect(totpCode(cfg, DateTime.fromMillisecondsSinceEpoch(1111111109000)), '07081804');
    expect(totpCode(cfg, DateTime.fromMillisecondsSinceEpoch(20000000000000)), '65353130');
    expect(parseTotp('not base32!'), isNull);
  });
}
