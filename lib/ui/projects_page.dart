import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/repo.dart';
import 'widgets.dart';

class ProjectsPage extends StatelessWidget {
  const ProjectsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AppBuilder(builder: (context) {
      final projects = listProjects();
      return Scaffold(
        appBar: AppBar(title: const Text('项目管理')),
        body: projects.isEmpty
            ? const EmptyView(icon: Icons.folder_off_outlined, text: '还没有项目')
            : ListView(children: [
                for (final p in projects)
                  ListTile(
                    leading: CircleAvatar(backgroundColor: hexColor(p.color), radius: 8),
                    title: Text(p.name),
                    subtitle: Text(
                      [if (p.description.isNotEmpty) p.description, '${p.entryCount} 个账号 · ${p.todoCount} 个待办'].join('\n'),
                    ),
                    isThreeLine: p.description.isNotEmpty,
                    onTap: () => _edit(context, p),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '删除',
                      onPressed: () async {
                        if (await confirm(context, '删除项目', '删除「${p.name}」后，其下的账号和待办会变为未分组。')) {
                          deleteProject(p.id);
                        }
                      },
                    ),
                  ),
              ]),
        floatingActionButton: FloatingActionButton(
          tooltip: '新建项目',
          onPressed: () => _edit(context, null),
          child: const Icon(Icons.add),
        ),
      );
    });
  }

  Future<void> _edit(BuildContext context, Project? p) async {
    final name = TextEditingController(text: p?.name ?? '');
    final desc = TextEditingController(text: p?.description ?? '');
    var color = p?.color ?? projectColors.first;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(p == null ? '新建项目' : '编辑项目'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, autofocus: p == null, decoration: const InputDecoration(labelText: '名称')),
            TextField(controller: desc, decoration: const InputDecoration(labelText: '描述（可选）')),
            const SizedBox(height: 16),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final c in projectColors)
                GestureDetector(
                  onTap: () => setState(() => color = c),
                  child: CircleAvatar(
                    radius: 14,
                    backgroundColor: hexColor(c),
                    child: color == c ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                  ),
                ),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                try {
                  saveProject(id: p?.id, name: name.text, color: color, description: desc.text);
                  Navigator.pop(ctx);
                } catch (e) {
                  toast(context, '$e');
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}
