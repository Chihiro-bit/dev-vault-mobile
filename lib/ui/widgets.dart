import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/models.dart';

Color hexColor(String? hex, [Color fallback = const Color(0xFF8A919E)]) {
  if (hex == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return fallback;
  return Color(int.parse(hex.substring(1), radix: 16) | 0xFF000000);
}

Color toneColor(BuildContext context, Tone tone) => switch (tone) {
      Tone.danger => Theme.of(context).colorScheme.error,
      Tone.warn => const Color(0xFFD97706),
      Tone.normal => Theme.of(context).colorScheme.onSurfaceVariant,
    };

void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
}

/// 复制到剪贴板；敏感内容 60 秒后若剪贴板未变则自动清除
Future<void> copyText(BuildContext context, String text, {String label = '内容', bool secret = false}) async {
  if (text.isEmpty) return;
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) toast(context, secret ? '已复制$label，60 秒后自动清除' : '已复制$label');
  if (secret) {
    Timer(const Duration(seconds: 60), () async {
      final cur = await Clipboard.getData(Clipboard.kTextPlain);
      if (cur?.text == text) await Clipboard.setData(const ClipboardData(text: ''));
    });
  }
}

Future<bool> confirm(BuildContext context, String title, String message, {String ok = '删除'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(
          style: ok == '删除' ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r == true;
}

/// 单行文本输入对话框，取消返回 null
Future<String?> promptText(BuildContext context, String title,
    {String initial = '', String? hint, bool multiline = false, bool allowEmpty = true}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        minLines: multiline ? 4 : 1,
        maxLines: multiline ? 10 : 1,
        decoration: InputDecoration(hintText: hint, border: const OutlineInputBorder()),
        onSubmitted: multiline ? null : (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            if (!allowEmpty && ctrl.text.trim().isEmpty) return;
            Navigator.pop(ctx, ctrl.text);
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

/// 执行操作，出错时提示错误信息
void guard(BuildContext context, void Function() fn) {
  try {
    fn();
  } catch (e) {
    toast(context, '$e');
  }
}

/// 数据变化时自动重建（每次重建都重新查询数据库，数据量小，足够快）
class AppBuilder extends StatelessWidget {
  const AppBuilder({super.key, required this.builder});
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: app, builder: (ctx, _) => builder(ctx));
}

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color, this.filled = false});
  final String text;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: filled ? c : c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, height: 1.4, color: filled ? Colors.white : c, fontWeight: FontWeight.w600)),
    );
  }
}

class ColorDot extends StatelessWidget {
  const ColorDot(this.color, {super.key, this.size = 8});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) =>
      Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

class EmptyView extends StatelessWidget {
  const EmptyView({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.outline;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 48, color: c),
        const SizedBox(height: 12),
        Text(text, style: TextStyle(color: c)),
      ]),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 8, 4),
        child: Row(children: [
          Expanded(
            child: Text(text,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
          ),
          if (trailing != null) trailing!,
        ]),
      );
}

IconData categoryIcon(String key) => switch (key) {
      'account' => Icons.person_outline,
      'git' => Icons.merge_type,
      'vpn' => Icons.vpn_lock_outlined,
      'server' => Icons.dns_outlined,
      'database' => Icons.storage_outlined,
      _ => Icons.key_outlined,
    };

/// 日期选择，返回 YYYY-MM-DD；取消返回 null
Future<String?> pickDate(BuildContext context, String current) async {
  final now = DateTime.now();
  final d = await showDatePicker(
    context: context,
    initialDate: current.isEmpty ? now : parseDate(current),
    firstDate: DateTime(2000),
    lastDate: DateTime(2100),
  );
  return d == null ? null : fmtDate(d);
}

/// 项目筛选菜单的选项
class ScopeMenu extends StatelessWidget {
  const ScopeMenu({super.key, required this.scope, required this.projects, required this.onChanged});
  final Scope scope;
  final List<Project> projects;
  final ValueChanged<Scope> onChanged;

  static String label(Scope scope, List<Project> projects) => switch (scope) {
        AllScope() => '全部项目',
        NoneScope() => '未分组',
        ProjectScope(:final id) => projects.where((p) => p.id == id).firstOrNull?.name ?? '全部项目',
      };

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<Scope>(
      tooltip: '按项目筛选',
      onSelected: onChanged,
      itemBuilder: (_) => [
        const PopupMenuItem(value: AllScope(), child: Text('全部项目')),
        const PopupMenuItem(value: NoneScope(), child: Text('未分组')),
        if (projects.isNotEmpty) const PopupMenuDivider(),
        for (final p in projects)
          PopupMenuItem(
            value: ProjectScope(p.id),
            child: Row(children: [ColorDot(hexColor(p.color)), const SizedBox(width: 10), Expanded(child: Text(p.name))]),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.folder_outlined, size: 20),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 96),
            child: Text(label(scope, projects), overflow: TextOverflow.ellipsis),
          ),
          const Icon(Icons.arrow_drop_down),
        ]),
      ),
    );
  }
}

/// 若当前筛选的项目已被删除（例如其他设备同步过来），退回全部
Scope validScope(Scope scope, List<Project> projects) =>
    scope is ProjectScope && !projects.any((p) => p.id == scope.id) ? const AllScope() : scope;
