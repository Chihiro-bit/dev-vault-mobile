import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/repo.dart';
import 'entry_detail_page.dart';
import 'entry_edit_page.dart';
import 'widgets.dart';

class EntriesPage extends StatefulWidget {
  const EntriesPage({super.key});

  @override
  State<EntriesPage> createState() => _EntriesPageState();
}

class _EntriesPageState extends State<EntriesPage> {
  Scope _scope = const AllScope();
  String? _category;
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
      final entries = listEntries(_scope, keyword: _search.text, category: _category);

      return Scaffold(
        appBar: AppBar(
          title: _searching
              ? TextField(
                  controller: _search,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: '搜索名称、账号、地址、标签…', border: InputBorder.none),
                  onChanged: (_) => setState(() {}),
                )
              : const Text('账号'),
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
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final c in [null, ...categories])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(c?.label ?? '全部'),
                      selected: _category == c?.key,
                      onSelected: (_) => setState(() => _category = c?.key),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? EmptyView(
                    icon: Icons.key_off_outlined,
                    text: _search.text.isNotEmpty || _category != null || _scope is! AllScope ? '没有匹配的账号' : '还没有账号，点右下角添加',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                    itemBuilder: (context, i) => _EntryTile(entries[i]),
                  ),
          ),
        ]),
        floatingActionButton: FloatingActionButton(
          // 底部导航用 IndexedStack 同时保留各页，悬浮按钮需各自的 Hero 标签
          heroTag: 'entries',
          tooltip: '添加账号',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => EntryEditPage(
                entry: Entry(projectId: _scope is ProjectScope ? (_scope as ProjectScope).id : null, category: _category ?? 'account'),
              ),
            ),
          ),
          child: const Icon(Icons.add),
        ),
      );
    });
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile(this.e);
  final Entry e;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final expiry = expiryInfo(e.expiresAt);
    final color = hexColor(e.projectColor, scheme.primary);
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading: CircleAvatar(
        backgroundColor: color.withOpacity(0.14),
        foregroundColor: color,
        child: Icon(categoryIcon(e.category), size: 20),
      ),
      title: Row(children: [
        Flexible(child: Text(e.title, overflow: TextOverflow.ellipsis)),
        if (e.env.isNotEmpty) ...[const SizedBox(width: 6), Pill(e.env, color: _envColor(e.env))],
        if (e.favorite) ...[const SizedBox(width: 4), const Icon(Icons.star, size: 16, color: Color(0xFFF59E0B))],
      ]),
      subtitle: Text(
        [
          if (e.username.isNotEmpty) e.username,
          if (e.projectName != null) e.projectName!,
          if (expiry != null && expiry.$2 != Tone.normal) expiry.$1,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: expiry != null && expiry.$2 != Tone.normal ? TextStyle(color: toneColor(context, expiry.$2)) : null,
      ),
      trailing: e.password.isEmpty
          ? null
          : IconButton(
              icon: const Icon(Icons.copy, size: 20),
              tooltip: '复制密码',
              onPressed: () => copyText(context, e.password, label: '密码', secret: true),
            ),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => EntryDetailPage(id: e.id!))),
    );
  }
}

Color _envColor(String env) => switch (env) {
      '开发' => const Color(0xFF16A37B),
      '测试' => const Color(0xFF3B6CFF),
      '预发' => const Color(0xFFD97706),
      '生产' => const Color(0xFFE5484D),
      _ => const Color(0xFF8A919E),
    };
