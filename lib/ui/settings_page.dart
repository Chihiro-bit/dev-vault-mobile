import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/cloud.dart';
import 'login_page.dart';
import 'projects_page.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AppBuilder(builder: (context) {
      final user = Cloud.user;
      final loggedIn = Cloud.loggedIn;
      return Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: ListView(children: [
          const SectionHeader('账号与云同步'),
          if (loggedIn && user != null) ...[
            ListTile(
              leading: CircleAvatar(child: Text(user.name.isEmpty ? '?' : user.name.characters.first)),
              title: Text(user.name),
              subtitle: Text('${user.username} · ${Cloud.serverUrl}', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const _SyncTile(),
            ListTile(
              leading: const Icon(Icons.password),
              title: const Text('修改主密码'),
              subtitle: const Text('修改后其他设备需重新登录'),
              onTap: () => _changePassword(context),
            ),
            ListTile(
              leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
              title: Text('退出登录', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              subtitle: const Text('本机数据保留，不再同步'),
              onTap: () async {
                if (await confirm(context, '退出登录', '退出后本机数据保留，但不再与云端同步。', ok: '退出')) {
                  await Cloud.logout();
                }
              },
            ),
          ] else
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('登录 / 注册'),
              subtitle: const Text('与桌面端同步账号和待办，数据端到端加密'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginPage())),
            ),
          const SectionHeader('数据'),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('项目管理'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProjectsPage())),
          ),
          const ListTile(
            leading: Icon(Icons.tune),
            title: Text('优先级与状态'),
            subtitle: Text('请在桌面端配置，会自动同步到手机'),
          ),
          const SectionHeader('安全'),
          SwitchListTile(
            secondary: const Icon(Icons.fingerprint),
            title: const Text('应用锁'),
            subtitle: const Text('打开应用或离开超过 30 秒后，需用指纹 / 面容 / 锁屏密码解锁'),
            value: app.lockEnabled,
            onChanged: (v) async {
              final err = await app.setLockEnabled(v);
              if (err != null && context.mounted) toast(context, err);
            },
          ),
          const SectionHeader('关于'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('DevVault 手机版 1.0.0'),
            subtitle: Text('数据保存在本机，密码等敏感字段加密存储；云同步为端到端加密，服务端无法解密。'),
          ),
        ]),
      );
    });
  }

  Future<void> _changePassword(BuildContext context) async {
    final current = TextEditingController();
    final next = TextEditingController();
    final again = TextEditingController();
    String? error;
    var busy = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('修改主密码'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: current, obscureText: true, decoration: const InputDecoration(labelText: '当前主密码')),
            TextField(controller: next, obscureText: true, decoration: const InputDecoration(labelText: '新主密码（至少 8 位）')),
            TextField(controller: again, obscureText: true, decoration: const InputDecoration(labelText: '再次输入新主密码')),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              ),
          ]),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (next.text != again.text) return setState(() => error = '两次输入的新密码不一致');
                      setState(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await Cloud.changePassword(current.text, next.text);
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (context.mounted) toast(context, '主密码已修改');
                      } catch (e) {
                        setState(() {
                          busy = false;
                          error = '$e';
                        });
                      }
                    },
              child: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('修改'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SyncTile extends StatelessWidget {
  const _SyncTile();

  // const 组件不会随父组件重建，需自己监听同步状态
  @override
  Widget build(BuildContext context) => AppBuilder(builder: _build);

  Widget _build(BuildContext context) {
    final s = app.syncStatus;
    final scheme = Theme.of(context).colorScheme;
    String two(int n) => n.toString().padLeft(2, '0');
    final last = s.lastSyncAt == null ? null : '${two(s.lastSyncAt!.hour)}:${two(s.lastSyncAt!.minute)}';
    final text = s.syncing
        ? '正在同步…'
        : s.error != null
            ? s.error!
            : [if (last != null) '上次同步 $last', if (s.pending > 0) '${s.pending} 项待上传'].join(' · ');
    return ListTile(
      leading: s.syncing
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
          : Icon(s.error != null ? Icons.sync_problem : Icons.cloud_done_outlined, color: s.error != null ? scheme.error : null),
      title: const Text('立即同步'),
      subtitle: text.isEmpty ? null : Text(text, style: s.error != null ? TextStyle(color: scheme.error) : null),
      onTap: s.syncing ? null : app.sync.syncNow,
    );
  }
}
