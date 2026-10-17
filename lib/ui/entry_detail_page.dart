import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/repo.dart';
import '../core/totp.dart';
import 'entry_edit_page.dart';
import 'widgets.dart';

class EntryDetailPage extends StatelessWidget {
  const EntryDetailPage({super.key, required this.id});
  final int id;

  @override
  Widget build(BuildContext context) {
    return AppBuilder(builder: (context) {
      final e = getEntry(id);
      if (e == null) {
        // 可能已在其他设备上删除
        return Scaffold(appBar: AppBar(), body: const EmptyView(icon: Icons.delete_outline, text: '该账号已被删除'));
      }
      final meta = categoryOf(e.category);
      final expiry = expiryInfo(e.expiresAt);
      final scheme = Theme.of(context).colorScheme;

      return Scaffold(
        appBar: AppBar(
          actions: [
            IconButton(
              icon: Icon(e.favorite ? Icons.star : Icons.star_border, color: e.favorite ? const Color(0xFFF59E0B) : null),
              tooltip: e.favorite ? '取消收藏' : '收藏',
              onPressed: () => toggleFavorite(id),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '编辑',
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => EntryEditPage(entry: e))),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: () async {
                if (await confirm(context, '删除账号', '确定删除「${e.title}」吗？')) {
                  deleteEntry(id);
                  if (context.mounted) Navigator.pop(context);
                }
              },
            ),
          ],
        ),
        body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Pill(meta.label, color: scheme.primary),
                if (e.env.isNotEmpty) Pill(e.env),
                if (e.projectName != null)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    ColorDot(hexColor(e.projectColor)),
                    const SizedBox(width: 4),
                    Text(e.projectName!, style: Theme.of(context).textTheme.bodySmall),
                  ]),
                if (expiry != null) Pill(expiry.$1, color: toneColor(context, expiry.$2)),
              ]),
            ]),
          ),
          if (e.url.isNotEmpty) _Field(label: meta.urlLabel, value: e.url),
          if (e.username.isNotEmpty) _Field(label: meta.userLabel, value: e.username),
          if (e.password.isNotEmpty) _Field(label: meta.pwdLabel, value: e.password, secret: true),
          if (e.verifyCode.isNotEmpty) _Field(label: meta.codeLabel, value: e.verifyCode),
          if (e.totp.isNotEmpty) _TotpField(secret: e.totp),
          for (final f in e.extra) _Field(label: f.key.isEmpty ? '（未命名）' : f.key, value: f.value, secret: f.secret),
          if (e.tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Wrap(spacing: 6, runSpacing: 6, children: [for (final t in splitTags(e.tags)) Chip(label: Text(t))]),
            ),
          if (e.notes.isNotEmpty) ...[
            const SectionHeader('备注'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SelectableText(e.notes),
            ),
          ],
          if (e.updatedAt.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
              child: Text('更新于 ${e.updatedAt}', style: TextStyle(color: scheme.outline, fontSize: 12)),
            ),
        ]),
      );
    });
  }
}

class _Field extends StatefulWidget {
  const _Field({required this.label, required this.value, this.secret = false});
  final String label;
  final String value;
  final bool secret;

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    final hidden = widget.secret && !_shown;
    return ListTile(
      title: Text(widget.label, style: Theme.of(context).textTheme.bodySmall),
      subtitle: Text(
        hidden ? '••••••••' : widget.value,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontFamily: widget.secret ? 'monospace' : null),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (widget.secret)
          IconButton(
            icon: Icon(_shown ? Icons.visibility_off_outlined : Icons.visibility_outlined),
            tooltip: _shown ? '隐藏' : '显示',
            onPressed: () => setState(() => _shown = !_shown),
          ),
        IconButton(
          icon: const Icon(Icons.copy),
          tooltip: '复制',
          onPressed: () => copyText(context, widget.value, label: widget.label, secret: widget.secret),
        ),
      ]),
      onTap: () => copyText(context, widget.value, label: widget.label, secret: widget.secret),
    );
  }
}

/// 每秒刷新的动态码
class _TotpField extends StatefulWidget {
  const _TotpField({required this.secret});
  final String secret;

  @override
  State<_TotpField> createState() => _TotpFieldState();
}

class _TotpFieldState extends State<_TotpField> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cfg = parseTotp(widget.secret);
    if (cfg == null) {
      return ListTile(
        title: Text('动态码', style: Theme.of(context).textTheme.bodySmall),
        subtitle: Text('密钥格式无效', style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );
    }
    final code = totpCode(cfg);
    final remaining = totpRemaining(cfg);
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      title: Text('动态码${cfg.issuer != null ? ' · ${cfg.issuer}' : ''}', style: Theme.of(context).textTheme.bodySmall),
      subtitle: Text(
        formatCode(code),
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontFamily: 'monospace',
              color: remaining <= 5 ? scheme.error : scheme.primary,
              letterSpacing: 2,
            ),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 28,
          height: 28,
          child: Stack(alignment: Alignment.center, children: [
            CircularProgressIndicator(value: remaining / cfg.period, strokeWidth: 3),
            Text('$remaining', style: const TextStyle(fontSize: 11)),
          ]),
        ),
        IconButton(icon: const Icon(Icons.copy), tooltip: '复制', onPressed: () => copyText(context, code, label: '动态码')),
      ]),
      onTap: () => copyText(context, code, label: '动态码'),
    );
  }
}
