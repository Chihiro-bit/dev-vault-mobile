import 'package:flutter/widgets.dart';
import 'package:local_auth/local_auth.dart';

import 'core/cloud.dart';
import 'core/db.dart';
import 'core/repo.dart';
import 'core/sync.dart';

const _kLock = 'lock.biometric';

/// 离开应用超过这么久，回来时需要重新验证
const _lockAfter = Duration(seconds: 30);

/// 全局状态：数据版本号（本地或云端数据变化时递增，界面据此重新查询）、登录与同步状态、应用锁
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  int revision = 0;
  late final SyncEngine sync;
  SyncStatus get syncStatus => sync.status;

  bool lockEnabled = false;
  bool locked = false;
  DateTime? _pausedAt;
  bool _authenticating = false;

  void init() {
    sync = SyncEngine(onStatus: (_) => notifyListeners(), onRemoteChange: _bump);
    Repo.onChange = () {
      _bump();
      sync.schedule();
    };
    Cloud.onSessionChange = (loggedIn) {
      loggedIn ? sync.start() : sync.stop();
      notifyListeners();
    };
    lockEnabled = getSetting(_kLock) == '1';
    locked = lockEnabled;
    WidgetsBinding.instance.addObserver(this);
    sync.start();
  }

  void _bump() {
    revision++;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // 验证对话框本身也会让应用短暂进入后台，不计入
        if (!_authenticating) _pausedAt ??= DateTime.now();
        sync.stop();
      case AppLifecycleState.resumed:
        final away = _pausedAt == null ? Duration.zero : DateTime.now().difference(_pausedAt!);
        _pausedAt = null;
        if (lockEnabled && away > _lockAfter) {
          locked = true;
          notifyListeners();
        }
        sync.start();
      default:
    }
  }

  /// 调起系统验证（指纹 / 面容 / 设备密码）
  Future<bool> authenticate(String reason) async {
    _authenticating = true;
    try {
      return await LocalAuthentication().authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(stickyAuth: true),
      );
    } catch (_) {
      return false;
    } finally {
      _authenticating = false;
    }
  }

  Future<void> unlock() async {
    if (await authenticate('验证身份以解锁 DevVault')) {
      locked = false;
      notifyListeners();
    }
  }

  /// 开启前先验证一次，确认设备支持且用户能通过
  Future<String?> setLockEnabled(bool enabled) async {
    if (enabled) {
      final auth = LocalAuthentication();
      if (!await auth.isDeviceSupported()) return '此设备未设置锁屏密码或生物识别';
      if (!await authenticate('验证身份以开启应用锁')) return '验证未通过';
    }
    setSetting(_kLock, enabled ? '1' : null);
    lockEnabled = enabled;
    notifyListeners();
    return null;
  }
}

final app = AppState();
