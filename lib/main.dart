import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';

import 'app_state.dart';
import 'core/db.dart';
import 'core/local_crypto.dart';
import 'ui/entries_page.dart';
import 'ui/settings_page.dart';
import 'ui/todos_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();
  await LocalCrypto.init();
  final dir = await getApplicationSupportDirectory();
  Db.open(p.join(dir.path, 'devvault.db'));
  app.init();
  runApp(const DevVaultApp());
}

const _seed = Color(0xFF3B6CFF);

class DevVaultApp extends StatelessWidget {
  const DevVaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DevVault',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: _seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: _seed, brightness: Brightness.dark, useMaterial3: true),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      // 应用锁覆盖在所有页面之上，解锁后保留原来的页面状态
      builder: (context, child) => ListenableBuilder(
        listenable: app,
        builder: (context, _) => Stack(children: [
          child!,
          if (app.locked) const _LockScreen(),
        ]),
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: const [EntriesPage(), TodosPage(), SettingsPage()]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.key_outlined), selectedIcon: Icon(Icons.key), label: '账号'),
          NavigationDestination(icon: Icon(Icons.task_alt_outlined), selectedIcon: Icon(Icons.task_alt), label: '待办'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}

class _LockScreen extends StatefulWidget {
  const _LockScreen();

  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  @override
  void initState() {
    super.initState();
    // 显示后自动调起验证
    WidgetsBinding.instance.addPostFrameCallback((_) => app.unlock());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: SafeArea(
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_outline, size: 56, color: scheme.primary),
            const SizedBox(height: 16),
            Text('DevVault 已锁定', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 24),
            FilledButton.icon(onPressed: app.unlock, icon: const Icon(Icons.fingerprint), label: const Text('解锁')),
          ]),
        ),
      ),
    );
  }
}
