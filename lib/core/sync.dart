/// 云同步引擎（端到端加密），与桌面端 src/main/sync.ts 逐段对应，协议见桌面端 docs/server-api.md。
///
/// - 本地修改由数据库触发器记录（sync_dirty / sync_tombstones），业务代码无需关心同步
/// - 一轮同步 = 拉取 → 合并 → 推送；推送遇到冲突时重新拉取后再推，最多 3 轮
/// - 冲突以记录为单位按修改时间「后写者胜」；删除与修改冲突时删除优先
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import 'cloud.dart';
import 'db.dart';
import 'e2ee.dart';
import 'local_crypto.dart';
import 'models.dart' show fmtDateTime;

const _kCursor = 'sync.cursor';
const _kAccount = 'sync.account';
const _page = 500;
const _maxRounds = 3;

final _table = {for (final t in syncTables) t.kind: t.table};
bool _isKind(String k) => _table.containsKey(k);

/// 被依赖的类型先写入；删除按相反顺序
const _order = ['priority', 'status', 'project', 'entry', 'todo', 'comment'];

class SyncStatus {
  const SyncStatus({this.syncing = false, this.lastSyncAt, this.error, this.pending = 0});
  final bool syncing;
  final DateTime? lastSyncAt;
  final String? error;
  final int pending;

  SyncStatus copyWith({bool? syncing, DateTime? lastSyncAt, String? error, bool clearError = false, int? pending}) =>
      SyncStatus(
        syncing: syncing ?? this.syncing,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
        error: clearError ? null : (error ?? this.error),
        pending: pending ?? this.pending,
      );
}

class _RemoteItem {
  _RemoteItem(Map<String, dynamic> j)
      : kind = j['kind'] as String,
        id = j['id'] as String,
        revision = (j['revision'] as num).toInt(),
        deleted = j['deleted'] == true,
        modifiedAt = (j['modifiedAt'] as num).toInt(),
        payload = j['payload'] as String?;

  final String kind;
  final String id;
  final int revision;
  final bool deleted;
  final int modifiedAt;
  final String? payload;
}

class _Decoded {
  _Decoded(this.item, this.data);
  final _RemoteItem item;
  final Map<String, dynamic>? data;
}

// ---------- 工具 ----------

String? _uidOf(String kind, Object? id) =>
    id == null ? null : Db.value('SELECT uid FROM ${_table[kind]} WHERE id = ?', [id]) as String?;

int? _idOf(String kind, Object? uid) =>
    uid == null ? null : Db.value('SELECT id FROM ${_table[kind]} WHERE uid = ?', [uid]) as int?;

int? _firstStatus(bool done) {
  for (final k in done ? ['done'] : ['todo', 'active']) {
    final id = Db.value('SELECT id FROM statuses WHERE kind = ? ORDER BY sort_order, id LIMIT 1', [k]);
    if (id != null) return id as int;
  }
  return null;
}

int? _defaultPriority() => Db.value('SELECT id FROM priorities ORDER BY is_default DESC, sort_order, id LIMIT 1') as int?;

String _nowStr() => fmtDateTime(DateTime.now());

String _s(Object? v, [String fallback = '']) => v is String ? v : fallback;
num _n(Object? v, [num fallback = 0]) => v is num && v.isFinite ? v : fallback;
bool _b(Object? v) => v == true || v == 1;

/// 本地记录 → 明文内容（解开本机加密的字段，把关联 id 转成 uid）
Map<String, Object?> _serialize(String kind, Row r) {
  switch (kind) {
    case 'priority':
      return {'label': r['label'], 'name': r['name'], 'color': r['color'], 'sort_order': r['sort_order'], 'is_default': _b(r['is_default'])};
    case 'status':
      return {'name': r['name'], 'color': r['color'], 'kind': r['kind'], 'sort_order': r['sort_order']};
    case 'project':
      return {'name': r['name'], 'color': r['color'], 'description': r['description'], 'sort_order': r['sort_order']};
    case 'entry':
      var extra = <Map<String, Object?>>[];
      try {
        extra = [
          for (final f in jsonDecode(r['extra'] as String) as List)
            {
              'key': f['key'] ?? '',
              'secret': f['secret'] == true,
              'value': f['secret'] == true ? LocalCrypto.decrypt(f['value'] as String?) : (f['value'] ?? ''),
            },
        ];
      } catch (_) {}
      return {
        'project': _uidOf('project', r['project_id']),
        'category': r['category'],
        'title': r['title'],
        'env': r['env'],
        'url': r['url'],
        'username': r['username'],
        'password': LocalCrypto.decrypt(r['password'] as String?),
        'verify_code': r['verify_code'],
        'totp': LocalCrypto.decrypt(r['totp'] as String?),
        'expires_at': r['expires_at'],
        'notes': r['notes'],
        'tags': r['tags'],
        'extra': extra,
        'favorite': _b(r['favorite']),
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
      };
    case 'todo':
      return {
        'project': _uidOf('project', r['project_id']),
        'parent': _uidOf('todo', r['parent_id']),
        'priority': _uidOf('priority', r['priority']),
        'status': _uidOf('status', r['status_id']),
        'title': r['title'],
        'notes': r['notes'],
        'done': _b(r['done']),
        'done_at': r['done_at'],
        'start_date': r['start_date'],
        'due_date': r['due_date'],
        'remind_at': r['remind_at'],
        'tags': r['tags'],
        'repeat': r['repeat'],
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
      };
    case 'comment':
      return {'todo': _uidOf('todo', r['todo_id']) ?? '', 'content': r['content'], 'created_at': r['created_at']};
  }
  throw StateError('未知类型 $kind');
}

/// 按 uid 插入或覆盖本地记录，并记下服务端版本；extraSet 为覆盖时额外执行的赋值
void _upsert(String kind, String uid, Map<String, Object?> data, _RemoteItem item, [List<String> extraSet = const []]) {
  final table = _table[kind]!;
  final cols = data.keys.toList();
  final sql = '''INSERT INTO $table (uid, ${cols.join(', ')}, sync_rev, sync_dirty, sync_mtime)
    VALUES (?, ${cols.map((_) => '?').join(', ')}, ?, 0, ?)
    ON CONFLICT(uid) DO UPDATE SET ${[...cols.map((c) => '$c = excluded.$c'), ...extraSet].join(', ')},
      sync_rev = excluded.sync_rev, sync_dirty = 0, sync_mtime = excluded.sync_mtime''';
  Db.run(sql, [uid, ...data.values, item.revision, item.modifiedAt]);
}

/// 云端内容写入本地（调用方已开启 sync_apply，触发器不会把这些写入当作本地修改）
void _applyUpsert(String kind, _RemoteItem item, Map<String, dynamic> d, Map<String, String?> parents) {
  switch (kind) {
    case 'priority':
      return _upsert(kind, item.id, {
        'label': _s(d['label'], '?'),
        'name': _s(d['name']),
        'color': _s(d['color'], '#3b6cff'),
        'sort_order': _n(d['sort_order']),
        'is_default': _b(d['is_default']),
      }, item);
    case 'status':
      return _upsert(kind, item.id, {
        'name': _s(d['name'], '?'),
        'color': _s(d['color'], '#8a919e'),
        'kind': const ['todo', 'active', 'done'].contains(d['kind']) ? d['kind'] : 'todo',
        'sort_order': _n(d['sort_order']),
      }, item);
    case 'project':
      return _upsert(kind, item.id, {
        'name': _s(d['name'], '未命名项目'),
        'color': _s(d['color'], '#3b6cff'),
        'description': _s(d['description']),
        'sort_order': _n(d['sort_order']),
      }, item);
    case 'entry':
      final extra = [
        for (final f in (d['extra'] is List ? d['extra'] as List : const []))
          {
            'key': _s(f is Map ? f['key'] : null),
            'secret': f is Map && _b(f['secret']),
            'value': f is Map && _b(f['secret']) ? LocalCrypto.encrypt(_s(f['value'])) : _s(f is Map ? f['value'] : null),
          },
      ];
      return _upsert(kind, item.id, {
        'project_id': _idOf('project', d['project']),
        'category': _s(d['category'], 'other'),
        'title': _s(d['title'], '未命名'),
        'env': _s(d['env']),
        'url': _s(d['url']),
        'username': _s(d['username']),
        'password': LocalCrypto.encrypt(_s(d['password'])),
        'verify_code': _s(d['verify_code']),
        'totp': LocalCrypto.encrypt(_s(d['totp'])),
        'expires_at': _s(d['expires_at']),
        'notes': _s(d['notes']),
        'tags': _s(d['tags']),
        'extra': jsonEncode(extra),
        'favorite': _b(d['favorite']),
        'created_at': _s(d['created_at'], _nowStr()),
        'updated_at': _s(d['updated_at'], _nowStr()),
      }, item);
    case 'todo':
      final done = _b(d['done']);
      // 父任务可能在本批稍后才写入，先置空，全部写完后再补上
      parents[item.id] = d['parent'] as String?;
      return _upsert(
        kind,
        item.id,
        {
          'project_id': _idOf('project', d['project']),
          'parent_id': _idOf('todo', d['parent']),
          'title': _s(d['title'], '未命名'),
          'notes': _s(d['notes']),
          'priority': _idOf('priority', d['priority']) ?? _defaultPriority(),
          'status_id': _idOf('status', d['status']) ?? _firstStatus(done),
          'done': done,
          'done_at': done ? d['done_at'] as String? : null,
          'start_date': _s(d['start_date']),
          'due_date': _s(d['due_date']),
          'remind_at': _s(d['remind_at']),
          'tags': _s(d['tags']),
          'repeat': _s(d['repeat']),
          'created_at': _s(d['created_at'], _nowStr()),
          'updated_at': _s(d['updated_at'], _nowStr()),
        },
        item,
        // 提醒时间变化后重新提醒；已完成的任务从桌面移除
        [
          'reminded = CASE WHEN remind_at <> excluded.remind_at THEN 0 ELSE reminded END',
          'pinned = CASE WHEN excluded.done = 1 THEN 0 ELSE pinned END',
        ],
      );
    case 'comment':
      final todoId = _idOf('todo', d['todo']);
      if (todoId == null) return; // 所属待办已在本机删除
      return _upsert(kind, item.id, {
        'todo_id': todoId,
        'content': _s(d['content']),
        'created_at': _s(d['created_at'], _nowStr()),
      }, item);
  }
}

// ---------- 拉取与合并 ----------

/// 合并云端变更，返回是否改动了本地数据
bool _applyRemote(List<_Decoded> items, int cursor) {
  var changed = false;
  Db.tx(() {
    Db.run('INSERT INTO sync_apply (x) VALUES (1)');
    final parents = <String, String?>{};
    final deletes = <_Decoded>[];

    final sorted = [...items]..sort((a, b) {
        final k = _order.indexOf(a.item.kind) - _order.indexOf(b.item.kind);
        return k != 0 ? k : a.item.revision - b.item.revision;
      });
    for (final x in sorted) {
      final item = x.item;
      final kind = item.kind;
      final table = _table[kind]!;
      final local = Db.get('SELECT id, sync_rev, sync_dirty, sync_mtime FROM $table WHERE uid = ?', [item.id]);
      final tomb = Db.get('SELECT rev, mtime FROM sync_tombstones WHERE kind = ? AND uid = ?', [kind, item.id]);

      if (local != null && (local['sync_rev'] as int) >= item.revision) continue; // 本机已是该版本

      // 删除优先：一端删除、另一端同时修改时保留删除
      if (tomb != null) {
        if (item.deleted) {
          Db.run('DELETE FROM sync_tombstones WHERE kind = ? AND uid = ?', [kind, item.id]);
        } else {
          Db.run('UPDATE sync_tombstones SET rev = ? WHERE kind = ? AND uid = ?', [item.revision, kind, item.id]);
        }
        continue;
      }
      if (!item.deleted && local != null && local['sync_dirty'] == 1 && (local['sync_mtime'] as int) > item.modifiedAt) {
        // 本机修改更晚：保留本机内容，记下云端版本号以便推送
        Db.run('UPDATE $table SET sync_rev = ? WHERE id = ?', [item.revision, local['id']]);
        continue;
      }

      if (item.deleted) {
        if (local != null) deletes.add(x);
        continue;
      }
      _applyUpsert(kind, item, x.data!, parents);
      changed = true;
    }

    // 补上父子关系
    parents.forEach((uid, parentUid) {
      if (parentUid != null) Db.run('UPDATE todos SET parent_id = ? WHERE uid = ?', [_idOf('todo', parentUid), uid]);
    });

    deletes.sort((a, b) => _order.indexOf(b.item.kind) - _order.indexOf(a.item.kind));
    for (final x in deletes) {
      Db.run('DELETE FROM ${_table[x.item.kind]} WHERE uid = ?', [x.item.id]);
      changed = true;
    }

    setSetting(_kCursor, '$cursor');
    Db.run('DELETE FROM sync_apply');

    // 云端删除了本机待办仍在使用的优先级 / 状态时，改用默认值（作为本机修改同步出去）
    final def = _defaultPriority();
    if (def != null) Db.run('UPDATE todos SET priority = ? WHERE priority NOT IN (SELECT id FROM priorities)', [def]);
    for (final done in [false, true]) {
      final s = _firstStatus(done);
      if (s != null) {
        Db.run('UPDATE todos SET status_id = ? WHERE done = ? AND status_id NOT IN (SELECT id FROM statuses)', [s, done]);
      }
    }
  });
  return changed;
}

int _cursor() => int.tryParse(getSetting(_kCursor) ?? '') ?? 0;

Future<bool> _pull(Uint8List key, String account) async {
  var since = _cursor();
  final items = <_RemoteItem>[];
  for (;;) {
    final page = await Cloud.request('/api/sync/pull?since=$since&limit=$_page') as Map<String, dynamic>;
    items.addAll((page['items'] as List).map((j) => _RemoteItem(j as Map<String, dynamic>)));
    since = (page['revision'] as num).toInt();
    if (page['hasMore'] != true) break;
  }
  if (Cloud.account != account) throw CloudException('账号已变更，同步已取消');

  final decoded = <_Decoded>[];
  for (final item in items) {
    if (!_isKind(item.kind)) continue; // 新版本客户端才支持的类型，忽略
    Map<String, dynamic>? data;
    if (!item.deleted) {
      try {
        data = decryptRecord(key, item.kind, item.id, item.payload ?? '') as Map<String, dynamic>;
      } catch (_) {
        throw CloudException('无法解密云端数据：数据密钥不匹配或数据已损坏，请重新登录');
      }
    }
    decoded.add(_Decoded(item, data));
  }
  return _applyRemote(decoded, since);
}

// ---------- 推送 ----------

class _Outgoing {
  _Outgoing(this.kind, this.id, this.baseRevision, this.deleted, this.modifiedAt, this.payload);
  final String kind;
  final String id;
  final int baseRevision;
  final bool deleted;
  final int modifiedAt;
  final String? payload;

  Map<String, Object?> toJson() => {
        'kind': kind,
        'id': id,
        'baseRevision': baseRevision,
        'deleted': deleted,
        'modifiedAt': modifiedAt,
        if (payload != null) 'payload': payload,
      };
}

List<_Outgoing> _collect(Uint8List key, int limit) {
  final out = <_Outgoing>[];
  for (final t in syncTables) {
    if (out.length >= limit) break;
    final rows = Db.all('SELECT * FROM ${t.table} WHERE sync_dirty = 1 AND uid IS NOT NULL ORDER BY id LIMIT ?', [limit - out.length]);
    for (final r in rows) {
      final uid = r['uid'] as String;
      out.add(_Outgoing(t.kind, uid, r['sync_rev'] as int, false, r['sync_mtime'] as int,
          encryptRecord(key, t.kind, uid, _serialize(t.kind, r))));
    }
  }
  if (out.length < limit) {
    for (final t in Db.all('SELECT kind, uid, rev, mtime FROM sync_tombstones ORDER BY mtime LIMIT ?', [limit - out.length])) {
      final kind = t['kind'] as String;
      if (_isKind(kind)) out.add(_Outgoing(kind, t['uid'] as String, t['rev'] as int, true, t['mtime'] as int, null));
    }
  }
  return out;
}

/// 推送本机修改，返回是否存在冲突（需要重新拉取）
Future<bool> _push(Uint8List key, String account) async {
  for (;;) {
    final changes = _collect(key, _page);
    if (changes.isEmpty) return false;
    final res = await Cloud.request('/api/sync/push', method: 'POST', body: {
      'changes': [for (final c in changes) c.toJson()],
    }) as Map<String, dynamic>;
    if (Cloud.account != account) throw CloudException('账号已变更，同步已取消');

    final sent = {for (final c in changes) '${c.kind}/${c.id}': c};
    Db.tx(() {
      for (final a in res['accepted'] as List) {
        final c = sent['${a['kind']}/${a['id']}'];
        if (c == null) continue;
        if (c.deleted) {
          Db.run('DELETE FROM sync_tombstones WHERE kind = ? AND uid = ? AND mtime = ?', [c.kind, c.id, c.modifiedAt]);
        } else {
          // 推送期间又被修改的记录保持待同步
          Db.run('UPDATE ${_table[c.kind]} SET sync_rev = ?, sync_dirty = CASE WHEN sync_mtime = ? THEN 0 ELSE 1 END WHERE uid = ?',
              [(a['revision'] as num).toInt(), c.modifiedAt, c.id]);
        }
      }
    });
    final conflicts = res['conflicts'] as List;
    if (conflicts.isNotEmpty) {
      _resolveConflicts(conflicts.cast<Map<String, dynamic>>());
      return true;
    }
    if (changes.length < _page) return false;
  }
}

/// 冲突的记录需要拉取云端版本后再合并；游标异常（如恢复了旧的本地数据库）时把游标回退，确保能拉到这些记录
void _resolveConflicts(List<Map<String, dynamic>> conflicts) {
  Db.tx(() {
    var cursor = _cursor();
    for (final c in conflicts) {
      final kind = c['kind'] as String;
      if (!_isKind(kind)) continue;
      final rev = (c['revision'] as num).toInt();
      if (rev == 0) {
        // 云端没有这条记录：修改按新记录重新上传，删除则无需再推送
        Db.run('UPDATE ${_table[kind]} SET sync_rev = 0 WHERE uid = ?', [c['id']]);
        Db.run('DELETE FROM sync_tombstones WHERE kind = ? AND uid = ?', [kind, c['id']]);
      } else if (rev - 1 < cursor) {
        cursor = rev - 1;
      }
    }
    setSetting(_kCursor, '$cursor');
  });
}

// ---------- 账号绑定与调度 ----------

/// 切换到另一个账号（或服务器）时，本机所有数据视为未同步，登录后整体上传并与云端合并
void _bindAccount(String account) {
  if (getSetting(_kAccount) == account) return;
  Db.tx(() {
    for (final t in syncTables) {
      Db.run('UPDATE ${t.table} SET sync_rev = 0, sync_dirty = 1');
    }
    Db.run('DELETE FROM sync_tombstones WHERE rev > 0');
    setSetting(_kCursor, '0');
    setSetting(_kAccount, account);
  });
}

int pendingCount() {
  final parts = syncTables.map((t) => '(SELECT COUNT(*) FROM ${t.table} WHERE sync_dirty = 1)');
  return Db.value('SELECT ${parts.join(' + ')} + (SELECT COUNT(*) FROM sync_tombstones)') as int;
}

class SyncEngine {
  SyncEngine({required this.onStatus, required this.onRemoteChange});

  final void Function(SyncStatus) onStatus;

  /// 云端数据写入了本地，界面需要刷新
  final void Function() onRemoteChange;

  SyncStatus status = const SyncStatus();
  Future<void>? _running;
  bool _rerun = false;
  Timer? _debounce;
  Timer? _interval;

  void _set(SyncStatus s) {
    status = s;
    onStatus(s);
  }

  Future<void> _runOnce() async {
    final account = Cloud.account;
    final key = Cloud.vaultKey;
    if (account == null || key == null) return;
    _bindAccount(account);
    _set(status.copyWith(syncing: true));
    var changed = false;
    try {
      for (var round = 0; round < _maxRounds; round++) {
        changed = await _pull(key, account) || changed;
        if (!await _push(key, account)) break;
      }
      _set(status.copyWith(lastSyncAt: DateTime.now(), clearError: true));
    } catch (e, st) {
      debugPrint('同步失败：$e\n$st');
      if (Cloud.account != null) _set(status.copyWith(error: e.toString()));
    } finally {
      if (changed) onRemoteChange();
      _set(Cloud.account != null ? status.copyWith(syncing: false, pending: pendingCount()) : const SyncStatus());
    }
  }

  /// 立即同步；正在同步时等待当前这轮结束后再补一轮
  Future<void> syncNow() {
    if (_running != null) {
      _rerun = true;
      return _running!;
    }
    return _running = _runOnce().whenComplete(() {
      _running = null;
      if (_rerun) {
        _rerun = false;
        syncNow();
      }
    });
  }

  /// 本地数据变化后调用：合并短时间内的多次修改，稍后再同步
  void schedule([Duration delay = const Duration(seconds: 3)]) {
    if (Cloud.account == null) return;
    _debounce?.cancel();
    _debounce = Timer(delay, syncNow);
  }

  /// 应用在前台时定期同步
  void start() {
    if (Cloud.account == null) return;
    _interval ??= Timer.periodic(const Duration(minutes: 2), (_) => syncNow());
    _set(status.copyWith(pending: pendingCount()));
    schedule(const Duration(milliseconds: 500));
  }

  void stop() {
    _interval?.cancel();
    _debounce?.cancel();
    _interval = _debounce = null;
  }
}
