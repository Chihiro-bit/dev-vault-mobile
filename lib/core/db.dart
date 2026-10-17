import 'package:sqlite3/sqlite3.dart';

/// 数据库结构与桌面端 src/main/db.ts 完全一致（含同步触发器），两端的同步逻辑因此可以逐行对应。
/// 手机端不使用的列（桌面任务条位置、附件）也保留，方便以后对齐。
const _now = "(datetime('now','localtime'))";

const _schemaV1 = '''
CREATE TABLE IF NOT EXISTS projects (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  name        TEXT NOT NULL,
  color       TEXT NOT NULL DEFAULT '#3b6cff',
  description TEXT NOT NULL DEFAULT '',
  sort_order  INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL DEFAULT $_now
);

CREATE TABLE IF NOT EXISTS entries (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id  INTEGER REFERENCES projects(id) ON DELETE SET NULL,
  category    TEXT NOT NULL DEFAULT 'account',
  title       TEXT NOT NULL,
  env         TEXT NOT NULL DEFAULT '',
  url         TEXT NOT NULL DEFAULT '',
  username    TEXT NOT NULL DEFAULT '',
  password    TEXT NOT NULL DEFAULT '',
  verify_code TEXT NOT NULL DEFAULT '',
  notes       TEXT NOT NULL DEFAULT '',
  tags        TEXT NOT NULL DEFAULT '',
  extra       TEXT NOT NULL DEFAULT '[]',
  favorite    INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL DEFAULT $_now,
  updated_at  TEXT NOT NULL DEFAULT $_now
);
CREATE INDEX IF NOT EXISTS idx_entries_project ON entries(project_id);

CREATE TABLE IF NOT EXISTS todos (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id  INTEGER REFERENCES projects(id) ON DELETE SET NULL,
  title       TEXT NOT NULL,
  notes       TEXT NOT NULL DEFAULT '',
  priority    INTEGER NOT NULL DEFAULT 1,
  due_date    TEXT NOT NULL DEFAULT '',
  done        INTEGER NOT NULL DEFAULT 0,
  done_at     TEXT,
  created_at  TEXT NOT NULL DEFAULT $_now,
  updated_at  TEXT NOT NULL DEFAULT $_now
);
CREATE INDEX IF NOT EXISTS idx_todos_project ON todos(project_id);
''';

const _schemaV2 = '''
ALTER TABLE todos ADD COLUMN pinned  INTEGER NOT NULL DEFAULT 0;
ALTER TABLE todos ADD COLUMN pin_top INTEGER NOT NULL DEFAULT 1;
ALTER TABLE todos ADD COLUMN pin_x   INTEGER;
ALTER TABLE todos ADD COLUMN pin_y   INTEGER;
UPDATE todos SET priority = CASE priority WHEN 2 THEN 1 WHEN 1 THEN 2 ELSE 3 END;
''';

const _schemaV3 = '''
CREATE TABLE IF NOT EXISTS priorities (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  label      TEXT NOT NULL,
  name       TEXT NOT NULL DEFAULT '',
  color      TEXT NOT NULL DEFAULT '#3b6cff',
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_default INTEGER NOT NULL DEFAULT 0
);
INSERT INTO priorities (id, label, name, color, sort_order, is_default) VALUES
  (1, 'P0', '紧急', '#e5484d', 0, 0),
  (2, 'P1', '高',   '#f76b15', 1, 0),
  (3, 'P2', '中',   '#3b6cff', 2, 1),
  (4, 'P3', '低',   '#8a919e', 3, 0);
UPDATE todos SET priority = priority + 1;
''';

const _schemaV4 = '''
CREATE TABLE IF NOT EXISTS settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''';

const _schemaV5 = '''
CREATE TABLE IF NOT EXISTS statuses (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  name       TEXT NOT NULL,
  color      TEXT NOT NULL DEFAULT '#8a919e',
  kind       TEXT NOT NULL DEFAULT 'todo',
  sort_order INTEGER NOT NULL DEFAULT 0
);
INSERT INTO statuses (id, name, color, kind, sort_order) VALUES
  (1, '待开始', '#8a919e', 'todo',   0),
  (2, '进行中', '#3b6cff', 'active', 1),
  (3, '待验证', '#e3a008', 'active', 2),
  (4, '已完成', '#16a37b', 'done',   3);

ALTER TABLE todos ADD COLUMN status_id  INTEGER;
ALTER TABLE todos ADD COLUMN parent_id  INTEGER REFERENCES todos(id) ON DELETE CASCADE;
ALTER TABLE todos ADD COLUMN start_date TEXT NOT NULL DEFAULT '';
ALTER TABLE todos ADD COLUMN tags       TEXT NOT NULL DEFAULT '';
ALTER TABLE todos ADD COLUMN repeat     TEXT NOT NULL DEFAULT '';
UPDATE todos SET status_id = CASE WHEN done = 1 THEN 4 ELSE 1 END;
CREATE INDEX IF NOT EXISTS idx_todos_parent ON todos(parent_id);

CREATE TABLE IF NOT EXISTS todo_comments (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  todo_id    INTEGER NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
  content    TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT $_now
);
CREATE INDEX IF NOT EXISTS idx_comments_todo ON todo_comments(todo_id);

CREATE TABLE IF NOT EXISTS attachments (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  entry_id   INTEGER REFERENCES entries(id) ON DELETE CASCADE,
  todo_id    INTEGER REFERENCES todos(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  size       INTEGER NOT NULL DEFAULT 0,
  stored     TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT $_now
);
CREATE INDEX IF NOT EXISTS idx_attach_entry ON attachments(entry_id);
CREATE INDEX IF NOT EXISTS idx_attach_todo ON attachments(todo_id);
''';

const _schemaV6 = '''
ALTER TABLE entries ADD COLUMN totp       TEXT NOT NULL DEFAULT '';
ALTER TABLE entries ADD COLUMN expires_at TEXT NOT NULL DEFAULT '';
ALTER TABLE todos   ADD COLUMN remind_at  TEXT NOT NULL DEFAULT '';
ALTER TABLE todos   ADD COLUMN reminded   INTEGER NOT NULL DEFAULT 0;
''';

class SyncTable {
  const SyncTable(this.table, this.kind, this.cols);
  final String table;
  final String kind;
  final List<String> cols;
}

/// 参与云同步的表及其同步类型、需要同步的列（与桌面端 SYNC_TABLES 一致）
const syncTables = [
  SyncTable('priorities', 'priority', ['label', 'name', 'color', 'sort_order', 'is_default']),
  SyncTable('statuses', 'status', ['name', 'color', 'kind', 'sort_order']),
  SyncTable('projects', 'project', ['name', 'color', 'description', 'sort_order']),
  SyncTable('entries', 'entry', [
    'project_id', 'category', 'title', 'env', 'url', 'username', 'password', 'verify_code', 'totp', 'expires_at', //
    'notes', 'tags', 'extra', 'favorite',
  ]),
  SyncTable('todos', 'todo', [
    'project_id', 'parent_id', 'title', 'notes', 'priority', 'status_id', 'done', 'done_at', 'start_date', //
    'due_date', 'remind_at', 'tags', 'repeat',
  ]),
  SyncTable('todo_comments', 'comment', ['content']),
];

/// 当前时间（毫秒时间戳）
const nowMs = "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)";

/// sync_apply 表中有行时表示正在写入云端拉取的数据，此时触发器不再标记待同步
const _notApplying = 'NOT EXISTS (SELECT 1 FROM sync_apply)';

String _schemaV7() => [
      'CREATE TABLE IF NOT EXISTS sync_apply (x INTEGER);',
      '''CREATE TABLE IF NOT EXISTS sync_tombstones (
    kind  TEXT NOT NULL,
    uid   TEXT NOT NULL,
    rev   INTEGER NOT NULL DEFAULT 0,
    mtime INTEGER NOT NULL,
    PRIMARY KEY (kind, uid)
  );''',
      for (final t in syncTables)
        '''
    ALTER TABLE ${t.table} ADD COLUMN uid        TEXT;
    ALTER TABLE ${t.table} ADD COLUMN sync_rev   INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE ${t.table} ADD COLUMN sync_dirty INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE ${t.table} ADD COLUMN sync_mtime INTEGER NOT NULL DEFAULT 0;
    UPDATE ${t.table} SET uid = lower(hex(randomblob(16))), sync_dirty = 1, sync_mtime = $nowMs;
    CREATE UNIQUE INDEX IF NOT EXISTS idx_${t.table}_uid ON ${t.table}(uid);

    CREATE TRIGGER trg_${t.table}_sync_ins AFTER INSERT ON ${t.table} WHEN $_notApplying
    BEGIN
      UPDATE ${t.table} SET uid = COALESCE(uid, lower(hex(randomblob(16)))), sync_dirty = 1, sync_mtime = $nowMs
      WHERE id = NEW.id;
    END;

    CREATE TRIGGER trg_${t.table}_sync_upd AFTER UPDATE OF ${t.cols.join(', ')} ON ${t.table} WHEN $_notApplying
    BEGIN
      UPDATE ${t.table} SET sync_dirty = 1, sync_mtime = $nowMs WHERE id = NEW.id;
    END;

    CREATE TRIGGER trg_${t.table}_sync_del AFTER DELETE ON ${t.table}
    WHEN OLD.uid IS NOT NULL AND $_notApplying
      AND (OLD.sync_rev > 0 OR EXISTS (SELECT 1 FROM settings WHERE key = 'sync.account'))
    BEGIN
      INSERT OR REPLACE INTO sync_tombstones (kind, uid, rev, mtime) VALUES ('${t.kind}', OLD.uid, OLD.sync_rev, $nowMs);
    END;''',
      // 内置的默认优先级和状态在每台设备上 id 相同，使用固定 uid，避免同步后出现重复的 P0~P3
      for (final kind in ['priority', 'status'])
        '''
    UPDATE ${kind == 'priority' ? 'priorities' : 'statuses'} SET uid = '$kind-' || id, sync_mtime = 1 WHERE id BETWEEN 1 AND 4;
    INSERT INTO sync_tombstones (kind, uid, rev, mtime)
      SELECT '$kind', '$kind-' || n, 0, 1 FROM (SELECT 1 AS n UNION SELECT 2 UNION SELECT 3 UNION SELECT 4)
      WHERE n NOT IN (SELECT id FROM ${kind == 'priority' ? 'priorities' : 'statuses'});''',
    ].join('\n');

typedef Row = Map<String, Object?>;

/// 同步的数据库访问封装（sqlite3 为 FFI 同步调用，与桌面端 better-sqlite3 用法一致）
class Db {
  static Database? _db;
  static int _txDepth = 0;

  static Database get raw => _db ?? (throw StateError('数据库尚未初始化'));

  static void open(String path) => _init(sqlite3.open(path));

  static void openInMemory() => _init(sqlite3.openInMemory());

  static void _init(Database db) {
    _db?.dispose();
    _db = db;
    _txDepth = 0;
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA foreign_keys = ON');
    final migrations = [_schemaV1, _schemaV2, _schemaV3, _schemaV4, _schemaV5, _schemaV6, _schemaV7()];
    for (var v = db.userVersion; v < migrations.length; v++) {
      tx(() {
        db.execute(migrations[v]);
        db.userVersion = v + 1;
      });
    }
  }

  static void close() {
    _db?.dispose();
    _db = null;
  }

  static List<Object?> _bind(List<Object?> params) => [for (final p in params) p is bool ? (p ? 1 : 0) : p];

  static List<Row> all(String sql, [List<Object?> params = const []]) =>
      [for (final r in raw.select(sql, _bind(params))) Map<String, Object?>.from(r)];

  static Row? get(String sql, [List<Object?> params = const []]) {
    final rs = raw.select(sql, _bind(params));
    return rs.isEmpty ? null : Map<String, Object?>.from(rs.first);
  }

  static Object? value(String sql, [List<Object?> params = const []]) => get(sql, params)?.values.first;

  /// 执行写入，返回影响的行数
  static int run(String sql, [List<Object?> params = const []]) {
    raw.execute(sql, _bind(params));
    return raw.updatedRows;
  }

  /// 插入并返回新行 id
  static int insert(String sql, [List<Object?> params = const []]) {
    raw.execute(sql, _bind(params));
    return raw.lastInsertRowId;
  }

  /// 事务；可嵌套（内层使用 SAVEPOINT）
  static T tx<T>(T Function() fn) {
    final sp = 'sp$_txDepth';
    raw.execute(_txDepth == 0 ? 'BEGIN' : 'SAVEPOINT $sp');
    _txDepth++;
    try {
      final r = fn();
      _txDepth--;
      raw.execute(_txDepth == 0 ? 'COMMIT' : 'RELEASE $sp');
      return r;
    } catch (_) {
      _txDepth--;
      raw.execute(_txDepth == 0 ? 'ROLLBACK' : 'ROLLBACK TO $sp; RELEASE $sp');
      rethrow;
    }
  }
}

String? getSetting(String key) => Db.value('SELECT value FROM settings WHERE key = ?', [key]) as String?;

void setSetting(String key, String? value) {
  if (value == null) {
    Db.run('DELETE FROM settings WHERE key = ?', [key]);
  } else {
    Db.run('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value', [key, value]);
  }
}
