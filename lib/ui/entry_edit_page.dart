import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/repo.dart';
import '../core/totp.dart';
import 'widgets.dart';

class EntryEditPage extends StatefulWidget {
  const EntryEditPage({super.key, required this.entry});

  /// id 为空表示新建
  final Entry entry;

  @override
  State<EntryEditPage> createState() => _EntryEditPageState();
}

class _ExtraRow {
  _ExtraRow(ExtraField f)
      : key = TextEditingController(text: f.key),
        value = TextEditingController(text: f.value),
        secret = f.secret;
  final TextEditingController key;
  final TextEditingController value;
  bool secret;
  bool shown = false;
}

class _EntryEditPageState extends State<EntryEditPage> {
  late final Entry _e = widget.entry;
  late String _category = _e.category;
  late int? _projectId = _e.projectId;
  late String _env = _e.env;
  late String _expires = _e.expiresAt;
  late bool _favorite = _e.favorite;
  late final _title = TextEditingController(text: _e.title);
  late final _url = TextEditingController(text: _e.url);
  late final _username = TextEditingController(text: _e.username);
  late final _password = TextEditingController(text: _e.password);
  late final _code = TextEditingController(text: _e.verifyCode);
  late final _totp = TextEditingController(text: _e.totp);
  late final _tags = TextEditingController(text: _e.tags.replaceAll(',', ', '));
  late final _notes = TextEditingController(text: _e.notes);
  late final List<_ExtraRow> _extra = _e.extra.map(_ExtraRow.new).toList();
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _showPassword = _e.id == null;
  }

  void _save() {
    final entry = Entry(
      id: _e.id,
      projectId: _projectId,
      category: _category,
      title: _title.text,
      env: _env,
      url: _url.text,
      username: _username.text,
      password: _password.text,
      verifyCode: _code.text,
      totp: _totp.text,
      expiresAt: _expires,
      notes: _notes.text,
      tags: _tags.text,
      extra: [for (final r in _extra) ExtraField(key: r.key.text, value: r.value.text, secret: r.secret)],
      favorite: _favorite,
    );
    if (entry.totp.trim().isNotEmpty && parseTotp(entry.totp) == null) {
      toast(context, '动态码密钥格式无效，请填写 base32 密钥或 otpauth:// 链接');
      return;
    }
    try {
      saveEntry(entry);
      Navigator.pop(context);
    } catch (e) {
      toast(context, '$e');
    }
  }

  InputDecoration _dec(String label, {String? hint, Widget? suffix}) =>
      InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder(), suffixIcon: suffix, isDense: true);

  @override
  Widget build(BuildContext context) {
    final meta = categoryOf(_category);
    final projects = listProjects();
    const gap = SizedBox(height: 14);

    return Scaffold(
      appBar: AppBar(
        title: Text(_e.id == null ? '添加账号' : '编辑账号'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _save, child: const Text('保存')),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final c in categories)
            ChoiceChip(
              avatar: Icon(categoryIcon(c.key), size: 18),
              label: Text(c.label),
              selected: _category == c.key,
              onSelected: (_) => setState(() => _category = c.key),
            ),
        ]),
        gap,
        TextField(controller: _title, decoration: _dec('名称 *', hint: '例如：商城后台管理员'), textInputAction: TextInputAction.next),
        gap,
        DropdownButtonFormField<int?>(
          value: projects.any((p) => p.id == _projectId) ? _projectId : null,
          decoration: _dec('所属项目'),
          items: [
            const DropdownMenuItem(value: null, child: Text('未分组')),
            for (final p in projects)
              DropdownMenuItem(
                value: p.id,
                child: Row(children: [ColorDot(hexColor(p.color)), const SizedBox(width: 8), Text(p.name)]),
              ),
          ],
          onChanged: (v) => setState(() => _projectId = v),
        ),
        gap,
        Text('环境', style: Theme.of(context).textTheme.bodySmall),
        Wrap(spacing: 8, children: [
          for (final env in ['', ...envs])
            ChoiceChip(
              label: Text(env.isEmpty ? '不区分' : env),
              selected: _env == env,
              onSelected: (_) => setState(() => _env = env),
            ),
          if (_env.isNotEmpty && !envs.contains(_env)) ChoiceChip(label: Text(_env), selected: true, onSelected: (_) {}),
        ]),
        gap,
        TextField(controller: _url, decoration: _dec(meta.urlLabel), keyboardType: TextInputType.url),
        gap,
        TextField(controller: _username, decoration: _dec(meta.userLabel)),
        gap,
        TextField(
          controller: _password,
          obscureText: !_showPassword,
          decoration: _dec(
            meta.pwdLabel,
            suffix: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                icon: const Icon(Icons.casino_outlined),
                tooltip: '生成随机密码',
                onPressed: () => setState(() {
                  _password.text = generatePassword();
                  _showPassword = true;
                }),
              ),
              IconButton(
                icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                onPressed: () => setState(() => _showPassword = !_showPassword),
              ),
            ]),
          ),
        ),
        gap,
        TextField(controller: _code, decoration: _dec(meta.codeLabel)),
        gap,
        TextField(
          controller: _totp,
          decoration: _dec('动态码密钥（TOTP）', hint: 'base32 密钥或 otpauth:// 链接'),
          onChanged: (_) => setState(() {}),
        ),
        if (_totp.text.trim().isNotEmpty && parseTotp(_totp.text) == null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 12),
            child: Text('密钥格式无效', style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
          ),
        gap,
        InputDecorator(
          decoration: _dec('有效期'),
          child: Row(children: [
            Expanded(
              child: InkWell(
                onTap: () async {
                  final d = await pickDate(context, _expires);
                  if (d != null) setState(() => _expires = d);
                },
                child: Text(_expires.isEmpty ? '长期有效' : _expires),
              ),
            ),
            if (_expires.isNotEmpty)
              InkWell(onTap: () => setState(() => _expires = ''), child: const Icon(Icons.clear, size: 20)),
          ]),
        ),
        const SectionHeader('附加字段'),
        for (final r in _extra) _extraRow(r),
        Wrap(spacing: 8, children: [
          for (final (key, secret) in meta.presets)
            if (!_extra.any((r) => r.key.text == key))
              ActionChip(
                label: Text(key),
                avatar: Icon(secret ? Icons.lock_outline : Icons.add, size: 16),
                onPressed: () => setState(() => _extra.add(_ExtraRow(ExtraField(key: key, secret: secret)))),
              ),
          ActionChip(
            label: const Text('自定义字段'),
            avatar: const Icon(Icons.add, size: 16),
            onPressed: () => setState(() => _extra.add(_ExtraRow(ExtraField()))),
          ),
        ]),
        gap,
        TextField(controller: _tags, decoration: _dec('标签', hint: '用逗号或空格分隔')),
        gap,
        TextField(controller: _notes, decoration: _dec('备注'), minLines: 3, maxLines: 8),
        gap,
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('收藏（置顶显示）'),
          value: _favorite,
          onChanged: (v) => setState(() => _favorite = v),
        ),
      ]),
    );
  }

  Widget _extraRow(_ExtraRow r) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        SizedBox(width: 96, child: TextField(controller: r.key, decoration: _dec('名称'))),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: r.value,
            obscureText: r.secret && !r.shown,
            decoration: _dec(
              '值',
              suffix: r.secret
                  ? IconButton(
                      icon: Icon(r.shown ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
                      onPressed: () => setState(() => r.shown = !r.shown),
                    )
                  : null,
            ),
          ),
        ),
        IconButton(
          icon: Icon(r.secret ? Icons.lock : Icons.lock_open_outlined, size: 20),
          tooltip: r.secret ? '敏感字段（加密、默认隐藏）' : '设为敏感字段',
          onPressed: () => setState(() => r.secret = !r.secret),
        ),
        IconButton(
          icon: const Icon(Icons.remove_circle_outline, size: 20),
          tooltip: '移除',
          onPressed: () => setState(() => _extra.remove(r)),
        ),
      ]),
    );
  }
}
