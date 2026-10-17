import 'dart:convert';
import 'dart:math';

import 'local_crypto.dart';

/// 'all' 全部项目、'none' 未分组、或指定项目 id
sealed class Scope {
  const Scope();
}

class AllScope extends Scope {
  const AllScope();
}

class NoneScope extends Scope {
  const NoneScope();
}

class ProjectScope extends Scope {
  const ProjectScope(this.id);
  final int id;
}

int? _int(Object? v) => v == null ? null : (v as num).toInt();
String _str(Object? v) => v == null ? '' : v as String;

class Project {
  Project.fromRow(Map<String, Object?> r)
      : id = _int(r['id'])!,
        name = _str(r['name']),
        color = _str(r['color']),
        description = _str(r['description']),
        entryCount = _int(r['entry_count']) ?? 0,
        todoCount = _int(r['todo_count']) ?? 0;

  final int id;
  final String name;
  final String color;
  final String description;
  final int entryCount;
  final int todoCount;
}

class ExtraField {
  ExtraField({this.key = '', this.value = '', this.secret = false});
  String key;
  String value;
  bool secret;

  Map<String, Object?> toJson() => {'key': key, 'value': value, 'secret': secret};
}

class Entry {
  Entry({
    this.id,
    this.projectId,
    this.projectName,
    this.projectColor,
    this.category = 'account',
    this.title = '',
    this.env = '',
    this.url = '',
    this.username = '',
    this.password = '',
    this.verifyCode = '',
    this.totp = '',
    this.expiresAt = '',
    this.notes = '',
    this.tags = '',
    List<ExtraField>? extra,
    this.favorite = false,
    this.updatedAt = '',
  }) : extra = extra ?? [];

  /// 读取数据库行，解开本机加密的字段
  factory Entry.fromRow(Map<String, Object?> r) {
    var extra = <ExtraField>[];
    try {
      extra = [
        for (final f in jsonDecode(_str(r['extra'])) as List)
          ExtraField(
            key: (f['key'] ?? '') as String,
            secret: f['secret'] == true,
            value: f['secret'] == true ? LocalCrypto.decrypt(f['value'] as String?) : (f['value'] ?? '') as String,
          ),
      ];
    } catch (_) {}
    return Entry(
      id: _int(r['id']),
      projectId: _int(r['project_id']),
      projectName: r['project_name'] as String?,
      projectColor: r['project_color'] as String?,
      category: _str(r['category']),
      title: _str(r['title']),
      env: _str(r['env']),
      url: _str(r['url']),
      username: _str(r['username']),
      password: LocalCrypto.decrypt(r['password'] as String?),
      verifyCode: _str(r['verify_code']),
      totp: LocalCrypto.decrypt(r['totp'] as String?),
      expiresAt: _str(r['expires_at']),
      notes: _str(r['notes']),
      tags: _str(r['tags']),
      extra: extra,
      favorite: _int(r['favorite']) == 1,
      updatedAt: _str(r['updated_at']),
    );
  }

  int? id;
  int? projectId;
  String? projectName;
  String? projectColor;
  String category;
  String title;
  String env;
  String url;
  String username;
  String password;
  String verifyCode;
  String totp;

  /// 有效期（YYYY-MM-DD），空表示长期有效
  String expiresAt;
  String notes;
  String tags;
  List<ExtraField> extra;
  bool favorite;
  String updatedAt;
}

typedef StatusKind = String; // 'todo' | 'active' | 'done'

class PriorityLevel {
  PriorityLevel.fromRow(Map<String, Object?> r)
      : id = _int(r['id'])!,
        label = _str(r['label']),
        name = _str(r['name']),
        color = _str(r['color']),
        isDefault = _int(r['is_default']) == 1;

  final int id;
  final String label;
  final String name;
  final String color;
  final bool isDefault;
}

class TodoStatus {
  TodoStatus.fromRow(Map<String, Object?> r)
      : id = _int(r['id'])!,
        name = _str(r['name']),
        color = _str(r['color']),
        kind = _str(r['kind']);

  final int id;
  final String name;
  final String color;
  final StatusKind kind;
}

class Todo {
  Todo.fromRow(Map<String, Object?> r)
      : id = _int(r['id'])!,
        projectId = _int(r['project_id']),
        projectName = r['project_name'] as String?,
        projectColor = r['project_color'] as String?,
        parentId = _int(r['parent_id']),
        parentTitle = r['parent_title'] as String?,
        title = _str(r['title']),
        notes = _str(r['notes']),
        priority = _int(r['priority']) ?? 0,
        priorityLabel = r['priority_label'] as String?,
        priorityName = r['priority_name'] as String?,
        priorityColor = r['priority_color'] as String?,
        statusId = _int(r['status_id']) ?? 0,
        statusName = r['status_name'] as String?,
        statusColor = r['status_color'] as String?,
        statusKind = _str(r['status_kind']),
        startDate = _str(r['start_date']),
        dueDate = _str(r['due_date']),
        remindAt = _str(r['remind_at']),
        tags = _str(r['tags']),
        repeat = _str(r['repeat']),
        subtaskTotal = _int(r['subtask_total']) ?? 0,
        subtaskDone = _int(r['subtask_done']) ?? 0,
        commentCount = _int(r['comment_count']) ?? 0,
        done = _int(r['done']) == 1,
        doneAt = r['done_at'] as String?,
        createdAt = _str(r['created_at']);

  final int id;
  final int? projectId;
  final String? projectName;
  final String? projectColor;
  final int? parentId;
  final String? parentTitle;
  final String title;
  final String notes;
  final int priority;
  final String? priorityLabel;
  final String? priorityName;
  final String? priorityColor;
  final int statusId;
  final String? statusName;
  final String? statusColor;
  final StatusKind statusKind;
  final String startDate;
  final String dueDate;

  /// 提醒时间（YYYY-MM-DDTHH:mm），空表示不提醒
  final String remindAt;
  final String tags;
  final String repeat;
  final int subtaskTotal;
  final int subtaskDone;
  final int commentCount;
  final bool done;
  final String? doneAt;
  final String createdAt;
}

class TodoComment {
  TodoComment.fromRow(Map<String, Object?> r)
      : id = _int(r['id'])!,
        content = _str(r['content']),
        createdAt = _str(r['created_at']);

  final int id;
  final String content;
  final String createdAt;
}

// ---------- 常量（与桌面端 constants.ts 一致） ----------

class CategoryMeta {
  const CategoryMeta(this.key, this.label, this.urlLabel, this.userLabel, this.pwdLabel, this.codeLabel, this.presets);
  final String key;
  final String label;
  final String urlLabel;
  final String userLabel;
  final String pwdLabel;
  final String codeLabel;

  /// 常用的附加字段：(名称, 是否敏感)
  final List<(String, bool)> presets;
}

const categories = [
  CategoryMeta('account', '测试账号', '登录地址', '账号', '密码', '固定验证码',
      [('手机号', false), ('角色', false), ('租户 / 组织', false), ('支付密码', true)]),
  CategoryMeta('git', 'Git', '平台 / 仓库地址', '用户名', '密码 / Token', '验证码',
      [('SSH 地址', false), ('Access Token', true), ('邮箱', false)]),
  CategoryMeta('vpn', 'VPN', '服务器地址', '用户名', '密码', '动态码 / 验证码',
      [('协议', false), ('共享密钥', true), ('客户端下载', false)]),
  CategoryMeta('server', '服务器', '主机 / IP', '用户名', '密码', '验证码', [('端口', false), ('密钥路径', false), ('跳板机', false)]),
  CategoryMeta('database', '数据库', '连接地址', '用户名', '密码', '验证码', [('端口', false), ('库名', false), ('类型', false)]),
  CategoryMeta('other', '其他', '地址', '账号', '密码', '验证码', [('说明', false), ('密钥', true)]),
];

CategoryMeta categoryOf(String key) => categories.firstWhere((c) => c.key == key, orElse: () => categories.last);

const envs = ['开发', '测试', '预发', '生产'];

const repeats = {'': '不重复', 'daily': '每天', 'weekdays': '每个工作日', 'weekly': '每周', 'monthly': '每月'};

const statusKinds = {'todo': '未开始', 'active': '进行中', 'done': '已完成'};

const projectColors = ['#3b6cff', '#16a37b', '#f59e0b', '#e5484d', '#9b5cf6', '#0ea5c6', '#e1488f', '#64748b'];

List<String> splitTags(String tags) => tags.isEmpty ? [] : tags.split(',').where((t) => t.isNotEmpty).toList();

// ---------- 日期 ----------

String _two(int n) => n.toString().padLeft(2, '0');

/// YYYY-MM-DD（本地时间）
String fmtDate(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// YYYY-MM-DD HH:mm:ss（本地时间），与 SQLite datetime('now','localtime') 相同
String fmtDateTime(DateTime d) => '${fmtDate(d)} ${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';

String today() => fmtDate(DateTime.now());

DateTime parseDate(String s) {
  final p = s.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

/// 距离某天还有几天（今天为 0，过去为负数）
int daysUntil(String date, [String? from]) {
  final a = parseDate(date);
  final b = parseDate(from ?? today());
  return DateTime.utc(a.year, a.month, a.day).difference(DateTime.utc(b.year, b.month, b.day)).inDays;
}

enum Tone { normal, warn, danger }

/// 截止日期的展示文案与状态（逾期 / 今天到期）
(String, Tone)? dueInfo(String due, bool done) {
  if (due.isEmpty) return null;
  final d = today();
  if (done) return (due, Tone.normal);
  if (due.compareTo(d) < 0) return ('逾期 ${due.substring(5)}', Tone.danger);
  if (due == d) return ('今天到期', Tone.warn);
  return (due.substring(0, 4) == d.substring(0, 4) ? due.substring(5) : due, Tone.normal);
}

/// 账号有效期的展示：已过期 / N 天内过期 / 长期
(String, Tone)? expiryInfo(String expires, [int warnDays = 7]) {
  if (expires.isEmpty) return null;
  final n = daysUntil(expires);
  if (n < 0) return ('已过期 ${-n} 天', Tone.danger);
  if (n == 0) return ('今天过期', Tone.danger);
  if (n <= warnDays) return ('$n 天后过期', Tone.warn);
  return ('有效期至 $expires', Tone.normal);
}

String generatePassword([int len = 16]) {
  const chars = r'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#$%^&*_-';
  final rng = Random.secure();
  return List.generate(len, (_) => chars[rng.nextInt(chars.length)]).join();
}
