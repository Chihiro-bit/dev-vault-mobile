import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/repo.dart';
import 'todo_detail_page.dart';
import 'widgets.dart';

class TodosPage extends StatefulWidget {
  const TodosPage({super.key});

  @override
  State<TodosPage> createState() => _TodosPageState();
}

class _TodosPageState extends State<TodosPage> {
  Scope _scope = const AllScope();
  bool _done = false;
  final _search = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppBuilder(builder: (context) {
      final projects = listProjects();
      _scope = validScope(_scope, projects);
      final todos = listTodos(_scope, keyword: _search.text, done: _done);

      return Scaffold(
        appBar: AppBar(
          title: _searching
              ? TextField(
                  controller: _search,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: '搜索待办、描述、标签…', border: InputBorder.none),
                  onChanged: (_) => setState(() {}),
                )
              : const Text('待办'),
          actions: [
            IconButton(
              icon: Icon(_searching ? Icons.close : Icons.search),
              tooltip: _searching ? '关闭搜索' : '搜索',
              onPressed: () => setState(() {
                _searching = !_searching;
                if (!_searching) _search.clear();
              }),
            ),
            if (!_searching) ScopeMenu(scope: _scope, projects: projects, onChanged: (s) => setState(() => _scope = s)),
          ],
        ),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(children: [
              Expanded(
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('未完成'), icon: Icon(Icons.radio_button_unchecked)),
                    ButtonSegment(value: true, label: Text('已完成'), icon: Icon(Icons.check_circle_outline)),
                  ],
                  selected: {_done},
                  onSelectionChanged: (s) => setState(() => _done = s.first),
                ),
              ),
              if (_done && todos.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.cleaning_services_outlined),
                  tooltip: '清理已完成',
                  onPressed: () async {
                    if (await confirm(context, '清理已完成', '删除当前范围内全部已完成的待办（仍有未完成子任务的除外）？')) {
                      final n = clearDoneTodos(_scope);
                      if (context.mounted) toast(context, '已清理 $n 条');
                    }
                  },
                ),
            ]),
          ),
          Expanded(
            child: todos.isEmpty
                ? EmptyView(
                    icon: _done ? Icons.inbox_outlined : Icons.task_alt,
                    text: _search.text.isNotEmpty ? '没有匹配的待办' : (_done ? '还没有已完成的待办' : '没有待办，轻松一下'),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: todos.length,
                    itemBuilder: (context, i) => TodoTile(todos[i]),
                  ),
          ),
        ]),
        floatingActionButton: _done
            ? null
            : FloatingActionButton(
                // 底部导航用 IndexedStack 同时保留各页，悬浮按钮需各自的 Hero 标签
                heroTag: 'todos',
                tooltip: '添加待办',
                onPressed: () => showQuickAdd(context, projectId: _scope is ProjectScope ? (_scope as ProjectScope).id : null),
                child: const Icon(Icons.add),
              ),
      );
    });
  }
}

class TodoTile extends StatelessWidget {
  const TodoTile(this.t, {super.key, this.showProject = true});
  final Todo t;
  final bool showProject;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final due = dueInfo(t.dueDate, t.done);
    final small = Theme.of(context).textTheme.bodySmall!;
    final meta = <Widget>[
      if (t.priorityLabel != null) Pill(t.priorityLabel!, color: hexColor(t.priorityColor), filled: !t.done),
      if (t.statusName != null && t.statusKind == 'active') Pill(t.statusName!, color: hexColor(t.statusColor)),
      if (due != null)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.event, size: 13, color: toneColor(context, due.$2)),
          const SizedBox(width: 2),
          Text(due.$1, style: small.copyWith(color: toneColor(context, due.$2))),
        ]),
      if (t.repeat.isNotEmpty) Icon(Icons.repeat, size: 14, color: scheme.outline),
      if (t.subtaskTotal > 0)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.checklist, size: 14, color: scheme.outline),
          const SizedBox(width: 2),
          Text('${t.subtaskDone}/${t.subtaskTotal}', style: small),
        ]),
      if (t.commentCount > 0)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.chat_bubble_outline, size: 13, color: scheme.outline),
          const SizedBox(width: 2),
          Text('${t.commentCount}', style: small),
        ]),
      if (showProject && t.projectName != null)
        Row(mainAxisSize: MainAxisSize.min, children: [
          ColorDot(hexColor(t.projectColor), size: 7),
          const SizedBox(width: 4),
          Text(t.projectName!, style: small),
        ]),
    ];

    return ListTile(
      contentPadding: const EdgeInsets.only(left: 4, right: 16),
      leading: Checkbox(
        value: t.done,
        shape: const CircleBorder(),
        onChanged: (_) => guard(context, () => toggleTodo(t.id)),
      ),
      title: Text(
        t.title,
        style: t.done ? TextStyle(decoration: TextDecoration.lineThrough, color: scheme.outline) : null,
      ),
      subtitle: meta.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: meta),
            ),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TodoDetailPage(id: t.id))),
    );
  }
}

/// 快速添加待办：标题 + 优先级 + 截止日期
Future<void> showQuickAdd(BuildContext context, {int? projectId, int? parentId}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _QuickAdd(projectId: projectId, parentId: parentId),
  );
}

class _QuickAdd extends StatefulWidget {
  const _QuickAdd({this.projectId, this.parentId});
  final int? projectId;
  final int? parentId;

  @override
  State<_QuickAdd> createState() => _QuickAddState();
}

class _QuickAddState extends State<_QuickAdd> {
  final _title = TextEditingController();
  final _levels = listPriorities();
  late int? _priority = _levels.where((l) => l.isDefault).firstOrNull?.id;
  String _due = '';

  void _submit() {
    if (_title.text.trim().isEmpty) return;
    try {
      createTodo(
        title: _title.text,
        projectId: widget.projectId,
        parentId: widget.parentId,
        priority: _priority,
        dueDate: _due,
      );
      Navigator.pop(context);
    } catch (e) {
      toast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          controller: _title,
          autofocus: true,
          decoration: InputDecoration(
            hintText: widget.parentId == null ? '要做什么？' : '子任务',
            border: const OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final l in _levels)
            ChoiceChip(
              label: Text(l.label),
              selected: _priority == l.id,
              selectedColor: hexColor(l.color).withOpacity(0.25),
              onSelected: (_) => setState(() => _priority = l.id),
            ),
          ActionChip(
            avatar: const Icon(Icons.event, size: 18),
            label: Text(_due.isEmpty ? '截止日期' : _due),
            onPressed: () async {
              final d = await pickDate(context, _due);
              if (d != null) setState(() => _due = d);
            },
          ),
        ]),
        const SizedBox(height: 12),
        Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: _submit, child: const Text('添加'))),
      ]),
    );
  }
}
