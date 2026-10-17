import 'dart:convert';

import 'db.dart';
import 'local_crypto.dart';
import 'models.dart';

/// 数据访问，逻辑与桌面端 src/main/repo.ts 对应。
/// 本地修改由数据库触发器自动标记为待同步，这里只需在修改后调用 [_changed] 通知界面刷新、安排同步。
class Repo {
  /// 本地数据变化后的回调（由 AppState 设置）
  static void Function()? onChange;

  static void _changed() => onChange?.call();
}

const _now = "datetime('now','localtime')";
final _dateRe = RegExp(r'^(\d{4}-\d{2}-\d{2})?$');
final _remindRe = RegExp(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})?$');
const _categoryKeys = ['account', 'git', 'vpn', 'server', 'database', 'other'];

class RepoException implements Exception {
  RepoException(this.message);
  final String message;
  @override
  String toString() => message;
}

// ---------- 通用查询片段 ----------

List<String> _scopeClause(Scope scope, String col, List<Object?> params) => switch (scope) {
      NoneScope() => ['$col IS NULL'],
      ProjectScope(:final id) => (() {
          params.add(id);
          return ['$col = ?'];
        })(),
      AllScope() => [],
    };

/// 空格分隔的多个关键词需全部命中，每个关键词在任一列中模糊匹配即可
List<String> _keywordClauses(String? keyword, List<String> cols, List<Object?> params) {
  final words = (keyword ?? '').trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  return [
    for (final w in words)
      () {
        final like = '%${w.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}')}%';
        for (final _ in cols) {
          params.add(like);
        }
        return '(${cols.map((c) => "$c LIKE ? ESCAPE '\\'").join(' OR ')})';
      }(),
  ];
}

String _where(List<String> clauses) => clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';

String normalizeTags(String tags) =>
    tags.split(RegExp(r'[,，\s]+')).map((t) => t.trim()).where((t) => t.isNotEmpty).toSet().join(',');

// ---------- 项目 ----------

List<Project> listProjects() => Db.all('''SELECT p.id, p.name, p.color, p.description,
    (SELECT COUNT(*) FROM entries e WHERE e.project_id = p.id) AS entry_count,
    (SELECT COUNT(*) FROM todos t WHERE t.project_id = p.id AND t.done = 0 AND t.parent_id IS NULL) AS todo_count
   FROM projects p ORDER BY p.sort_order, p.id''').map(Project.fromRow).toList();

int saveProject({int? id, required String name, required String color, String description = ''}) {
  final n = name.trim();
  if (n.isEmpty) throw RepoException('项目名称不能为空');
  late int result;
  if (id != null) {
    Db.run('UPDATE projects SET name = ?, color = ?, description = ? WHERE id = ?', [n, color, description.trim(), id]);
    result = id;
  } else {
    final max = Db.value('SELECT COALESCE(MAX(sort_order), 0) FROM projects') as int;
    result = Db.insert('INSERT INTO projects (name, color, description, sort_order) VALUES (?, ?, ?, ?)',
        [n, color, description.trim(), max + 1]);
  }
  Repo._changed();
  return result;
}

void deleteProject(int id) {
  Db.run('DELETE FROM projects WHERE id = ?', [id]);
  Repo._changed();
}

// ---------- 账号凭据 ----------

List<Entry> listEntries(Scope scope, {String? keyword, String? category}) {
  final params = <Object?>[];
  final clauses = [
    ..._scopeClause(scope, 'e.project_id', params),
    if (category != null) () {
      params.add(category);
      return 'e.category = ?';
    }(),
    ..._keywordClauses(keyword, [
      'e.title', 'e.username', 'e.url', 'e.notes', 'e.tags', 'e.env', 'e.verify_code', 'e.extra', 'p.name', //
    ], params),
  ];
  return Db.all('''SELECT e.*, p.name AS project_name, p.color AS project_color
     FROM entries e LEFT JOIN projects p ON p.id = e.project_id
     ${_where(clauses)}
     ORDER BY e.favorite DESC, e.updated_at DESC, e.id DESC''', params).map(Entry.fromRow).toList();
}

Entry? getEntry(int id) {
  final r = Db.get('''SELECT e.*, p.name AS project_name, p.color AS project_color
     FROM entries e LEFT JOIN projects p ON p.id = e.project_id WHERE e.id = ?''', [id]);
  return r == null ? null : Entry.fromRow(r);
}

int saveEntry(Entry e) {
  final title = e.title.trim();
  if (title.isEmpty) throw RepoException('名称不能为空');
  final extra = [
    for (final f in e.extra)
      if (f.key.trim().isNotEmpty || f.value.isNotEmpty)
        {'key': f.key.trim(), 'secret': f.secret, 'value': f.secret ? LocalCrypto.encrypt(f.value) : f.value},
  ];
  final data = [
    e.projectId,
    _categoryKeys.contains(e.category) ? e.category : 'other',
    title,
    e.env,
    e.url.trim(),
    e.username,
    LocalCrypto.encrypt(e.password),
    e.verifyCode.trim(),
    LocalCrypto.encrypt(e.totp.trim()),
    _dateRe.hasMatch(e.expiresAt) ? e.expiresAt : '',
    e.notes,
    normalizeTags(e.tags),
    jsonEncode(extra),
    e.favorite,
  ];
  late int id;
  if (e.id != null) {
    Db.run('''UPDATE entries SET project_id=?, category=?, title=?, env=?, url=?, username=?, password=?,
        verify_code=?, totp=?, expires_at=?, notes=?, tags=?, extra=?, favorite=?, updated_at=$_now WHERE id=?''',
        [...data, e.id]);
    id = e.id!;
  } else {
    id = Db.insert('''INSERT INTO entries (project_id, category, title, env, url, username, password, verify_code, totp,
        expires_at, notes, tags, extra, favorite) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''', data);
  }
  Repo._changed();
  return id;
}

void deleteEntry(int id) {
  Db.run('DELETE FROM entries WHERE id = ?', [id]);
  Repo._changed();
}

void toggleFavorite(int id) {
  Db.run('UPDATE entries SET favorite = 1 - favorite WHERE id = ?', [id]);
  Repo._changed();
}

// ---------- 待办 ----------

const _todoSelect = '''SELECT t.id, t.project_id, t.parent_id, t.title, t.notes, t.priority, t.status_id,
    t.start_date, t.due_date, t.remind_at, t.tags, t.repeat, t.done, t.done_at, t.created_at, t.updated_at,
    p.name AS project_name, p.color AS project_color,
    pr.label AS priority_label, pr.name AS priority_name, pr.color AS priority_color,
    st.name AS status_name, st.color AS status_color,
    COALESCE(st.kind, CASE WHEN t.done = 1 THEN 'done' ELSE 'todo' END) AS status_kind,
    par.title AS parent_title,
    (SELECT COUNT(*) FROM todos c WHERE c.parent_id = t.id) AS subtask_total,
    (SELECT COUNT(*) FROM todos c WHERE c.parent_id = t.id AND c.done = 1) AS subtask_done,
    (SELECT COUNT(*) FROM todo_comments m WHERE m.todo_id = t.id) AS comment_count
  FROM todos t
  LEFT JOIN projects p ON p.id = t.project_id
  LEFT JOIN priorities pr ON pr.id = t.priority
  LEFT JOIN statuses st ON st.id = t.status_id
  LEFT JOIN todos par ON par.id = t.parent_id''';

/// 按等级顺序排序，未定级（等级已不存在）的排最后
const _todoOrder = "t.done ASC, COALESCE(pr.sort_order, 1000000) ASC, (t.due_date = '') ASC, t.due_date ASC, t.id DESC";

/// 顶层待办；done 为 null 时不区分完成状态
List<Todo> listTodos(Scope scope, {String? keyword, bool? done}) {
  final params = <Object?>[];
  final clauses = [
    't.parent_id IS NULL',
    if (done != null) 't.done = ${done ? 1 : 0}',
    ..._scopeClause(scope, 't.project_id', params),
    ..._keywordClauses(keyword, ['t.title', 't.notes', 't.tags', 'p.name'], params),
  ];
  return Db.all('$_todoSelect ${_where(clauses)} ORDER BY $_todoOrder', params).map(Todo.fromRow).toList();
}

List<Todo> listSubtasks(int parentId) =>
    Db.all('$_todoSelect WHERE t.parent_id = ? ORDER BY t.done ASC, t.id ASC', [parentId]).map(Todo.fromRow).toList();

Todo? getTodo(int id) {
  final r = Db.get('$_todoSelect WHERE t.id = ?', [id]);
  return r == null ? null : Todo.fromRow(r);
}

Map<String, Object?>? _statusById(int? id) =>
    id == null ? null : Db.get('SELECT id, kind FROM statuses WHERE id = ?', [id]);

/// 按顺序取第一个属于给定分类的状态
int firstStatus(List<String> kinds) {
  for (final k in kinds) {
    final id = Db.value('SELECT id FROM statuses WHERE kind = ? ORDER BY sort_order, id LIMIT 1', [k]);
    if (id != null) return id as int;
  }
  throw RepoException('没有可用的状态');
}

bool _priorityExists(int id) => Db.get('SELECT 1 FROM priorities WHERE id = ?', [id]) != null;

int defaultPriorityId() {
  final id = Db.value('SELECT id FROM priorities ORDER BY is_default DESC, sort_order, id LIMIT 1');
  if (id == null) throw RepoException('没有可用的优先级');
  return id as int;
}

/// 新建待办。子任务沿用父任务的项目
int createTodo({
  required String title,
  int? projectId,
  int? parentId,
  String notes = '',
  int? priority,
  int? statusId,
  String startDate = '',
  String dueDate = '',
  String remindAt = '',
  String tags = '',
  String repeat = '',
}) {
  final t = title.trim();
  if (t.isEmpty) throw RepoException('待办内容不能为空');
  final parent = parentId == null ? null : Db.get('SELECT id, project_id FROM todos WHERE id = ?', [parentId]);
  final status = _statusById(statusId) ?? _statusById(firstStatus(['todo', 'active']))!;
  final done = status['kind'] == 'done';
  final id = Db.insert('''INSERT INTO todos (project_id, parent_id, title, notes, priority, status_id, done, done_at,
      start_date, due_date, remind_at, tags, repeat)
     VALUES (?, ?, ?, ?, ?, ?, ?, CASE WHEN ? = 1 THEN $_now ELSE NULL END, ?, ?, ?, ?, ?)''', [
    parent != null ? parent['project_id'] : projectId,
    parent?['id'],
    t,
    notes,
    priority != null && _priorityExists(priority) ? priority : defaultPriorityId(),
    status['id'],
    done,
    done,
    _dateRe.hasMatch(startDate) ? startDate : '',
    _dateRe.hasMatch(dueDate) ? dueDate : '',
    _remindRe.hasMatch(remindAt) ? remindAt : '',
    normalizeTags(tags),
    repeats.containsKey(repeat) ? repeat : '',
  ]);
  Repo._changed();
  return id;
}

/// 修改状态，同步完成标记；重复任务完成时自动生成下一次
void _setStatus(int id, int statusId) {
  final st = _statusById(statusId);
  if (st == null) throw RepoException('状态不存在');
  final cur = Db.get('SELECT done FROM todos WHERE id = ?', [id]);
  if (cur == null) return;
  final done = st['kind'] == 'done';
  Db.run('''UPDATE todos SET status_id = ?, done = ?,
      done_at = CASE WHEN ? = 1 THEN COALESCE(done_at, $_now) ELSE NULL END,
      pinned = CASE WHEN ? = 1 THEN 0 ELSE pinned END,
      updated_at = $_now
     WHERE id = ?''', [st['id'], done, done, done, id]);
  if (done && cur['done'] == 0) _spawnNextOccurrence(id);
}

/// 勾选 / 取消勾选：在第一个「已完成」与第一个「未开始」状态之间切换
void toggleTodo(int id) {
  final cur = Db.get('SELECT done FROM todos WHERE id = ?', [id]);
  if (cur == null) return;
  Db.tx(() => _setStatus(id, cur['done'] == 1 ? firstStatus(['todo', 'active']) : firstStatus(['done'])));
  Repo._changed();
}

/// 逐字段修改；未传入的字段保持不变。清空可空字段（如项目）请传 [clearProject]
void patchTodo(
  int id, {
  String? title,
  String? notes,
  int? priority,
  int? statusId,
  int? projectId,
  bool clearProject = false,
  String? startDate,
  String? dueDate,
  String? remindAt,
  String? tags,
  String? repeat,
}) {
  Db.tx(() {
    final sets = <String>[];
    final params = <Object?>[];
    void set(String col, Object? v) {
      sets.add('$col = ?');
      params.add(v);
    }

    if (title != null) {
      if (title.trim().isEmpty) throw RepoException('待办内容不能为空');
      set('title', title.trim());
    }
    if (notes != null) set('notes', notes);
    if (priority != null) set('priority', _priorityExists(priority) ? priority : defaultPriorityId());
    if (startDate != null) set('start_date', _dateRe.hasMatch(startDate) ? startDate : '');
    if (dueDate != null) set('due_date', _dateRe.hasMatch(dueDate) ? dueDate : '');
    if (remindAt != null) {
      set('remind_at', _remindRe.hasMatch(remindAt) ? remindAt : '');
      set('reminded', 0);
    }
    if (tags != null) set('tags', normalizeTags(tags));
    if (repeat != null) set('repeat', repeats.containsKey(repeat) ? repeat : '');
    if (projectId != null || clearProject) {
      set('project_id', projectId);
      // 子任务跟随父任务的项目
      Db.run('UPDATE todos SET project_id = ? WHERE parent_id = ?', [projectId, id]);
    }
    if (sets.isNotEmpty) Db.run('UPDATE todos SET ${sets.join(', ')}, updated_at = $_now WHERE id = ?', [...params, id]);
    if (statusId != null) _setStatus(id, statusId);
  });
  Repo._changed();
}

void _advance(List<int> ymd, String repeat) {
  var d = DateTime(ymd[0], ymd[1], ymd[2]);
  switch (repeat) {
    case 'daily':
      d = DateTime(d.year, d.month, d.day + 1);
    case 'weekly':
      d = DateTime(d.year, d.month, d.day + 7);
    case 'weekdays':
      do {
        d = DateTime(d.year, d.month, d.day + 1);
      } while (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday);
    case 'monthly':
      final day = ymd[2];
      final lastDay = DateTime(d.year, d.month + 2, 0).day;
      d = DateTime(d.year, d.month + 1, day < lastDay ? day : lastDay);
  }
  ymd
    ..[0] = d.year
    ..[1] = d.month
    ..[2] = d.day;
}

/// 下一次的截止日期：从原截止日期（无则今天）起按规则推进，直到不早于今天
String nextDueDate(String due, String repeat, [String? todayStr]) {
  final t = todayStr ?? today();
  final d = parseDate(due.isEmpty ? t : due);
  final ymd = [d.year, d.month, d.day];
  String cur;
  do {
    _advance(ymd, repeat);
    cur = fmtDate(DateTime(ymd[0], ymd[1], ymd[2]));
  } while (cur.compareTo(t) < 0);
  return cur;
}

void _spawnNextOccurrence(int id) {
  final t = Db.get('SELECT * FROM todos WHERE id = ?', [id]);
  if (t == null || (t['repeat'] as String).isEmpty) return;
  final repeat = t['repeat'] as String;
  final oldDue = t['due_date'] as String;
  final oldStart = t['start_date'] as String;
  final remind = t['remind_at'] as String;

  final due = nextDueDate(oldDue, repeat);
  var start = '';
  if (oldStart.isNotEmpty) {
    final gap = oldDue.isNotEmpty ? parseDate(oldDue).difference(parseDate(oldStart)).inHours / 24 : 0;
    final s = parseDate(due);
    start = fmtDate(DateTime(s.year, s.month, s.day - (gap < 0 ? 0 : gap.round())));
  }
  // 提醒时间保留原来的时刻，日期对齐到新的截止日期
  final newId = createTodo(
    title: t['title'] as String,
    projectId: t['project_id'] as int?,
    parentId: t['parent_id'] as int?,
    notes: t['notes'] as String,
    priority: t['priority'] as int?,
    startDate: start,
    dueDate: due,
    remindAt: remind.isNotEmpty ? '${due}T${remind.substring(11, 16)}' : '',
    tags: t['tags'] as String,
    repeat: repeat,
  );
  // 子任务作为检查清单一并复制（重置为未完成）
  for (final c in Db.all('SELECT title, notes, priority, tags FROM todos WHERE parent_id = ? ORDER BY id', [id])) {
    createTodo(
      title: c['title'] as String,
      notes: c['notes'] as String,
      priority: c['priority'] as int?,
      tags: c['tags'] as String,
      projectId: t['project_id'] as int?,
      parentId: newId,
    );
  }
  // 原任务不再重复
  Db.run("UPDATE todos SET repeat = '' WHERE id = ?", [id]);
}

void deleteTodo(int id) {
  // 子任务、进展记录随外键级联删除
  Db.run('DELETE FROM todos WHERE id = ?', [id]);
  Repo._changed();
}

/// 清理已完成的顶层任务（仍有未完成子任务的除外），其子任务一并删除
int clearDoneTodos(Scope scope) {
  final params = <Object?>[];
  final clauses = [
    'done = 1',
    'parent_id IS NULL',
    'NOT EXISTS (SELECT 1 FROM todos c WHERE c.parent_id = todos.id AND c.done = 0)',
    ..._scopeClause(scope, 'project_id', params),
  ];
  final n = Db.run('DELETE FROM todos ${_where(clauses)}', params);
  Repo._changed();
  return n;
}

// ---------- 进展记录 ----------

List<TodoComment> listComments(int todoId) =>
    Db.all('SELECT * FROM todo_comments WHERE todo_id = ? ORDER BY id', [todoId]).map(TodoComment.fromRow).toList();

void addComment(int todoId, String content) {
  if (content.trim().isEmpty) throw RepoException('内容不能为空');
  Db.insert('INSERT INTO todo_comments (todo_id, content) VALUES (?, ?)', [todoId, content.trim()]);
  Repo._changed();
}

void deleteComment(int id) {
  Db.run('DELETE FROM todo_comments WHERE id = ?', [id]);
  Repo._changed();
}

// ---------- 状态 / 优先级（手机端只读，在桌面端配置） ----------

List<TodoStatus> listStatuses() =>
    Db.all('SELECT id, name, color, kind FROM statuses ORDER BY sort_order, id').map(TodoStatus.fromRow).toList();

List<PriorityLevel> listPriorities() => Db.all('SELECT id, label, name, color, is_default FROM priorities ORDER BY sort_order, id')
    .map(PriorityLevel.fromRow)
    .toList();
