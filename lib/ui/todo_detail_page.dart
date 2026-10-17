import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/repo.dart';
import 'todos_page.dart';
import 'widgets.dart';

class TodoDetailPage extends StatefulWidget {
  const TodoDetailPage({super.key, required this.id});
  final int id;

  @override
  State<TodoDetailPage> createState() => _TodoDetailPageState();
}

class _TodoDetailPageState extends State<TodoDetailPage> {
  final _comment = TextEditingController();

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  void _patch(void Function() fn) => guard(context, fn);

  /// 从选项列表中选择一项
  Future<T?> _choose<T>(String title, List<(T, Widget)> options, T current) {
    return showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(title, style: Theme.of(ctx).textTheme.titleMedium),
          ),
          for (final (value, label) in options)
            ListTile(
              title: label,
              trailing: value == current ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary) : null,
              onTap: () => Navigator.pop(ctx, value),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppBuilder(builder: (context) {
      final t = getTodo(widget.id);
      if (t == null) {
        return Scaffold(appBar: AppBar(), body: const EmptyView(icon: Icons.delete_outline, text: '该待办已被删除'));
      }
      final scheme = Theme.of(context).colorScheme;
      final statuses = listStatuses();
      final levels = listPriorities();
      final projects = listProjects();
      final subtasks = listSubtasks(t.id);
      final comments = listComments(t.id);
      final due = dueInfo(t.dueDate, t.done);

      return Scaffold(
        appBar: AppBar(
          title: t.parentTitle != null ? Text(t.parentTitle!, style: const TextStyle(fontSize: 16)) : null,
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: () async {
                final sub = t.subtaskTotal > 0 ? '，其 ${t.subtaskTotal} 个子任务也会一并删除' : '';
                if (await confirm(context, '删除待办', '确定删除「${t.title}」吗$sub？')) {
                  deleteTodo(t.id);
                  if (context.mounted) Navigator.pop(context);
                }
              },
            ),
          ],
        ),
        body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          ListTile(
            leading: Checkbox(
              value: t.done,
              shape: const CircleBorder(),
              onChanged: (_) => _patch(() => toggleTodo(t.id)),
            ),
            title: Text(
              t.title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    decoration: t.done ? TextDecoration.lineThrough : null,
                    color: t.done ? scheme.outline : null,
                  ),
            ),
            onTap: () async {
              final v = await promptText(context, '修改标题', initial: t.title, allowEmpty: false);
              if (v != null) _patch(() => patchTodo(t.id, title: v));
            },
          ),
          const Divider(),
          _row(
            Icons.flag_outlined,
            '状态',
            Pill(t.statusName ?? '—', color: hexColor(t.statusColor)),
            () async {
              final v = await _choose('状态', [
                for (final s in statuses)
                  (s.id, Row(children: [ColorDot(hexColor(s.color)), const SizedBox(width: 10), Text(s.name)])),
              ], t.statusId);
              if (v != null) _patch(() => patchTodo(t.id, statusId: v));
            },
          ),
          _row(
            Icons.priority_high,
            '优先级',
            Pill('${t.priorityLabel ?? '—'} ${t.priorityName ?? '未定级'}', color: hexColor(t.priorityColor)),
            () async {
              final v = await _choose('优先级', [
                for (final l in levels) (l.id, Row(children: [Pill(l.label, color: hexColor(l.color), filled: true), const SizedBox(width: 10), Text(l.name)])),
              ], t.priority);
              if (v != null) _patch(() => patchTodo(t.id, priority: v));
            },
          ),
          if (t.parentId == null)
            _row(
              Icons.folder_outlined,
              '项目',
              Text(t.projectName ?? '未分组'),
              () async {
                final v = await _choose<int>('所属项目', [
                  (0, const Text('未分组')),
                  for (final p in projects)
                    (p.id, Row(children: [ColorDot(hexColor(p.color)), const SizedBox(width: 10), Text(p.name)])),
                ], t.projectId ?? 0);
                if (v != null) _patch(() => v == 0 ? patchTodo(t.id, clearProject: true) : patchTodo(t.id, projectId: v));
              },
            ),
          _dateRow(Icons.play_circle_outline, '开始日期', t.startDate, (d) => patchTodo(t.id, startDate: d)),
          _row(
            Icons.event,
            '截止日期',
            Text(t.dueDate.isEmpty ? '未设置' : t.dueDate, style: due == null ? null : TextStyle(color: toneColor(context, due.$2))),
            () async {
              final d = await pickDate(context, t.dueDate);
              if (d != null) _patch(() => patchTodo(t.id, dueDate: d));
            },
            onClear: t.dueDate.isEmpty ? null : () => _patch(() => patchTodo(t.id, dueDate: '')),
          ),
          _row(
            Icons.alarm,
            '提醒',
            Text(t.remindAt.isEmpty ? '未设置' : t.remindAt.replaceFirst('T', ' ')),
            () => _pickRemind(t),
            onClear: t.remindAt.isEmpty ? null : () => _patch(() => patchTodo(t.id, remindAt: '')),
          ),
          _row(Icons.repeat, '重复', Text(repeats[t.repeat] ?? '不重复'), () async {
            final v = await _choose('重复', [for (final e in repeats.entries) (e.key, Text(e.value))], t.repeat);
            if (v != null) _patch(() => patchTodo(t.id, repeat: v));
          }),
          _row(
            Icons.sell_outlined,
            '标签',
            t.tags.isEmpty
                ? const Text('无')
                : Wrap(spacing: 4, runSpacing: 4, children: [for (final tag in splitTags(t.tags)) Pill(tag)]),
            () async {
              final v = await promptText(context, '标签', initial: t.tags.replaceAll(',', ', '), hint: '用逗号或空格分隔');
              if (v != null) _patch(() => patchTodo(t.id, tags: v));
            },
          ),
          SectionHeader('描述', trailing: IconButton(icon: const Icon(Icons.edit_outlined, size: 20), onPressed: () => _editNotes(t))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: t.notes.isEmpty
                ? InkWell(
                    onTap: () => _editNotes(t),
                    child: Text('添加描述…', style: TextStyle(color: scheme.outline)),
                  )
                : SelectableText(t.notes),
          ),
          if (t.parentId == null) ...[
            SectionHeader(
              '子任务${subtasks.isEmpty ? '' : '（${t.subtaskDone}/${t.subtaskTotal}）'}',
              trailing: IconButton(
                icon: const Icon(Icons.add, size: 22),
                tooltip: '添加子任务',
                onPressed: () => showQuickAdd(context, parentId: t.id),
              ),
            ),
            for (final s in subtasks) TodoTile(s, showProject: false),
          ],
          SectionHeader('进展记录${comments.isEmpty ? '' : '（${comments.length}）'}'),
          for (final c in comments)
            ListTile(
              title: SelectableText(c.content),
              subtitle: Text(c.createdAt, style: TextStyle(color: scheme.outline, fontSize: 12)),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: '删除',
                onPressed: () async {
                  if (await confirm(context, '删除进展记录', '确定删除这条记录吗？')) deleteComment(c.id);
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _comment,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(hintText: '记录进展…', border: OutlineInputBorder(), isDense: true),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send),
                onPressed: () => _patch(() {
                  addComment(t.id, _comment.text);
                  _comment.clear();
                }),
              ),
            ]),
          ),
        ]),
      );
    });
  }

  Widget _row(IconData icon, String label, Widget value, VoidCallback onTap, {VoidCallback? onClear}) => ListTile(
        leading: Icon(icon, size: 22),
        title: Text(label),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 200), child: value),
          if (onClear != null) IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: onClear, tooltip: '清除'),
        ]),
        onTap: onTap,
        dense: true,
      );

  Widget _dateRow(IconData icon, String label, String value, void Function(String) save) => _row(
        icon,
        label,
        Text(value.isEmpty ? '未设置' : value),
        () async {
          final d = await pickDate(context, value);
          if (d != null) _patch(() => save(d));
        },
        onClear: value.isEmpty ? null : () => _patch(() => save('')),
      );

  Future<void> _editNotes(Todo t) async {
    final v = await promptText(context, '描述', initial: t.notes, multiline: true);
    if (v != null) _patch(() => patchTodo(t.id, notes: v));
  }

  Future<void> _pickRemind(Todo t) async {
    final base = t.remindAt.isNotEmpty ? t.remindAt.substring(0, 10) : (t.dueDate.isNotEmpty ? t.dueDate : '');
    final d = await pickDate(context, base);
    if (d == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: t.remindAt.length >= 16
          ? TimeOfDay(hour: int.parse(t.remindAt.substring(11, 13)), minute: int.parse(t.remindAt.substring(14, 16)))
          : const TimeOfDay(hour: 9, minute: 0),
    );
    if (time == null) return;
    String two(int n) => n.toString().padLeft(2, '0');
    _patch(() => patchTodo(t.id, remindAt: '${d}T${two(time.hour)}:${two(time.minute)}'));
  }
}
