import 'package:flutter/material.dart';

import '../core/cloud.dart';
import 'widgets.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _register = false;
  bool _busy = false;
  String? _error;
  bool _showPassword = false;
  final _server = TextEditingController(text: Cloud.serverUrl);
  final _username = TextEditingController(text: Cloud.user?.username ?? '');
  final _password = TextEditingController();
  final _again = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();

  /// http:// 连接非本机地址时提示：数据仍是端到端加密的，但登录令牌会明文传输
  bool get _insecure {
    final u = _server.text.trim().toLowerCase();
    return u.startsWith('http://') && !RegExp(r'^http://(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)').hasMatch(u);
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (_register && _password.text != _again.text) {
      setState(() => _error = '两次输入的主密码不一致');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_register) {
        await Cloud.register(_server.text, _username.text, _password.text, name: _name.text, email: _email.text);
      } else {
        await Cloud.login(_server.text, _username.text, _password.text);
      }
      if (mounted) {
        Navigator.pop(context);
        toast(context, _register ? '注册成功，开始同步' : '登录成功，开始同步');
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const gap = SizedBox(height: 14);
    InputDecoration dec(String label, {String? hint, Widget? suffix}) =>
        InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder(), suffixIcon: suffix);

    return Scaffold(
      appBar: AppBar(title: Text(_register ? '注册账号' : '登录')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          SegmentedButton<bool>(
            segments: const [ButtonSegment(value: false, label: Text('登录')), ButtonSegment(value: true, label: Text('注册'))],
            selected: {_register},
            onSelectionChanged: (s) => setState(() {
              _register = s.first;
              _error = null;
            }),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _server,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: dec('服务器地址', hint: 'https://devvault.example.com'),
            onChanged: (_) => setState(() {}),
          ),
          if (_insecure)
            const Padding(
              padding: EdgeInsets.only(top: 6, left: 4),
              child: Text('未使用 HTTPS：数据仍是端到端加密的，但登录令牌会以明文传输',
                  style: TextStyle(color: Color(0xFFD97706), fontSize: 12)),
            ),
          gap,
          TextField(controller: _username, autocorrect: false, decoration: dec('账号')),
          gap,
          TextField(
            controller: _password,
            obscureText: !_showPassword,
            decoration: dec(
              '主密码',
              hint: _register ? '至少 8 位' : null,
              suffix: IconButton(
                icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                onPressed: () => setState(() => _showPassword = !_showPassword),
              ),
            ),
            onSubmitted: _register ? null : (_) => _submit(),
          ),
          if (_register) ...[
            gap,
            TextField(controller: _again, obscureText: !_showPassword, decoration: dec('再次输入主密码')),
            gap,
            TextField(controller: _name, decoration: dec('昵称（可选）')),
            gap,
            TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: dec('邮箱（可选）')),
            gap,
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: scheme.errorContainer.withOpacity(0.5), borderRadius: BorderRadius.circular(8)),
              child: Text(
                '主密码用于在本机加密数据，服务端无法解密，也无法帮你找回。忘记主密码将无法恢复云端数据，请务必牢记。',
                style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
              ),
            ),
          ],
          if (_error != null) ...[
            gap,
            Text(_error!, style: TextStyle(color: scheme.error)),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _submit,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: _busy
                ? const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 12),
                    Text('正在加密验证…'),
                  ])
                : Text(_register ? '注册并开始同步' : '登录'),
          ),
          const SizedBox(height: 16),
          Text(
            '登录后本机数据会与云端合并。服务端部署方法见 dev-vault-server 项目。',
            style: TextStyle(color: scheme.outline, fontSize: 12),
          ),
        ]),
      ),
    );
  }
}
