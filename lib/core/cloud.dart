import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'db.dart';
import 'e2ee.dart';
import 'local_crypto.dart';

/// 云端（服务端）客户端，逻辑与桌面端 src/main/cloud.ts 对应，接口约定见桌面端 docs/server-api.md。
/// 登录信息保存在 settings 表中，令牌和数据密钥用本机密钥加密。
const _kServer = 'cloud.serverUrl';
const _kToken = 'cloud.token';
const _kUser = 'cloud.user';
const _kVaultKey = 'cloud.vaultKey';

/// 客户端支持的服务端接口版本
const apiVersion = 1;
const _timeout = Duration(seconds: 15);

class CloudException implements Exception {
  CloudException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CloudUser {
  CloudUser({required this.id, required this.name, required this.username, this.email});

  factory CloudUser.fromJson(Map<String, dynamic> j) => CloudUser(
        id: '${j['id']}',
        name: (j['name'] as String?)?.isNotEmpty == true ? j['name'] as String : j['username'] as String,
        username: j['username'] as String,
        email: j['email'] as String?,
      );

  final String id;
  final String name;

  /// 登录名
  final String username;
  final String? email;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'username': username, 'email': email};
}

class ServerInfo {
  ServerInfo(this.name, this.version, this.allowRegistration);
  final String name;
  final String version;
  final bool allowRegistration;
}

class Cloud {
  /// 登录 / 退出时回调
  static void Function(bool loggedIn)? onSessionChange;

  /// 测试时可替换
  static http.Client client = http.Client();

  static String get serverUrl => getSetting(_kServer) ?? '';

  static CloudUser? get user {
    try {
      final raw = getSetting(_kUser);
      return raw == null ? null : CloudUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static String get _token => LocalCrypto.decrypt(getSetting(_kToken));

  /// 当前登录账号的数据密钥；未登录返回 null
  static Uint8List? get vaultKey {
    final k = LocalCrypto.decrypt(getSetting(_kVaultKey));
    return k.isEmpty ? null : base64.decode(k);
  }

  static bool get loggedIn => user != null && _token.isNotEmpty && vaultKey != null;

  /// 当前账号标识（服务器 + 用户 id），用于判断同步期间账号是否变化
  static String? get account => loggedIn ? '$serverUrl|${user!.id}' : null;

  static String normalizeUrl(String url) {
    final u = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (!RegExp(r'^https?://[^/\s]+', caseSensitive: false).hasMatch(u)) {
      throw CloudException('服务器地址需以 http:// 或 https:// 开头');
    }
    return u;
  }

  static Future<http.Response> _send(Future<http.Response> Function() fn) async {
    try {
      return await fn().timeout(_timeout);
    } on TimeoutException {
      throw CloudException('连接服务器超时，请检查地址或网络');
    } on Exception {
      throw CloudException('无法连接服务器，请检查地址或网络');
    }
  }

  static String _readError(http.Response res) {
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is Map && body['message'] is String) return body['message'] as String;
    } catch (_) {}
    return res.statusCode == 401 ? '账号或密码错误' : '请求失败（HTTP ${res.statusCode}）';
  }

  static Future<Map<String, dynamic>> _postJson(String url, Object body) async {
    final res = await _send(() => client.post(Uri.parse(url),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode(body)));
    if (res.statusCode < 200 || res.statusCode >= 300) throw CloudException(_readError(res));
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  /// 连接测试：读取服务器信息并检查接口版本
  static Future<ServerInfo> serverInfo(String url) async {
    final base = normalizeUrl(url);
    final res = await _send(() => client.get(Uri.parse('$base/api/server/info')));
    if (res.statusCode != 200) {
      throw CloudException(res.statusCode == 404 ? '该地址不是 DevVault 服务器' : _readError(res));
    }
    Map<String, dynamic>? info;
    try {
      info = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {}
    final v = info?['apiVersion'];
    if (info == null || v is! int) throw CloudException('该地址不是 DevVault 服务器');
    if (v > apiVersion) throw CloudException('服务器版本较新，请升级客户端');
    if (v < apiVersion) throw CloudException('服务器版本过旧，请联系管理员升级');
    return ServerInfo('${info['name'] ?? ''}', '${info['version'] ?? ''}', info['allowRegistration'] == true);
  }

  static void _saveSession(String base, Map<String, dynamic> data, Uint8List vault) {
    if (data['token'] is! String || data['user'] is! Map || (data['user'] as Map)['id'] == null) {
      throw CloudException('服务器返回的数据格式不正确');
    }
    final u = CloudUser.fromJson(data['user'] as Map<String, dynamic>);
    Db.tx(() {
      setSetting(_kServer, base);
      setSetting(_kToken, LocalCrypto.encrypt(data['token'] as String));
      setSetting(_kVaultKey, LocalCrypto.encrypt(base64.encode(vault)));
      setSetting(_kUser, jsonEncode(u.toJson()));
    });
    onSessionChange?.call(true);
  }

  static String get _device => 'DevVault 手机版 · ${Platform.operatingSystem}';

  static String _checkInput(String username, String password) {
    final u = username.trim();
    if (u.isEmpty || password.isEmpty) throw CloudException('请输入账号和密码');
    return u;
  }

  static Future<void> login(String url, String username, String password) async {
    final base = normalizeUrl(url);
    final u = _checkInput(username, password);
    await serverInfo(base);

    final pre = await _postJson('$base/api/auth/prelogin', {'username': u});
    final keys = await deriveKeys(password, KdfParams.fromJson(pre['kdf'] as Map<String, dynamic>));
    final data = await _postJson('$base/api/auth/login', {'username': u, 'authKey': keys.authKey, 'device': _device});
    _saveSession(base, data, unwrapVaultKey(data['encryptedVaultKey'] as String, keys.wrapKey));
  }

  static Future<void> register(String url, String username, String password, {String name = '', String email = ''}) async {
    final base = normalizeUrl(url);
    final u = _checkInput(username, password);
    if (password.length < 8) throw CloudException('主密码至少 8 位');
    final info = await serverInfo(base);
    if (!info.allowRegistration) throw CloudException('该服务器未开放注册，请联系管理员');

    final kdf = KdfParams.generate();
    final keys = await deriveKeys(password, kdf);
    final vault = newVaultKey();
    final data = await _postJson('$base/api/auth/register', {
      'username': u,
      'name': name.trim(),
      'email': email.trim().isEmpty ? null : email.trim(),
      'kdf': kdf.toJson(),
      'authKey': keys.authKey,
      'encryptedVaultKey': wrapVaultKey(vault, keys.wrapKey),
      'device': _device,
    });
    _saveSession(base, data, vault);
  }

  static void _clearSession() {
    Db.tx(() {
      setSetting(_kToken, null);
      setSetting(_kUser, null);
      setSetting(_kVaultKey, null);
    });
    onSessionChange?.call(false);
  }

  static Future<void> logout() async {
    final base = serverUrl;
    final t = _token;
    _clearSession();
    // 尽力通知服务端注销，失败不影响本地退出
    if (base.isNotEmpty && t.isNotEmpty) {
      try {
        await client.post(Uri.parse('$base/api/auth/logout'), headers: {'Authorization': 'Bearer $t'}).timeout(_timeout);
      } catch (_) {}
    }
  }

  /// 修改主密码：用新密码重新包裹数据密钥，其他设备需重新登录
  static Future<void> changePassword(String current, String next) async {
    final u = user;
    final vault = vaultKey;
    if (u == null || vault == null) throw CloudException('该功能需要登录后使用');
    if (next.length < 8) throw CloudException('主密码至少 8 位');

    final pre = await _postJson('$serverUrl/api/auth/prelogin', {'username': u.username});
    final currentKeys = await deriveKeys(current, KdfParams.fromJson(pre['kdf'] as Map<String, dynamic>));
    final nextKdf = KdfParams.generate();
    final nextKeys = await deriveKeys(next, nextKdf);
    await request('/api/auth/password', method: 'POST', body: {
      'currentAuthKey': currentKeys.authKey,
      'kdf': nextKdf.toJson(),
      'authKey': nextKeys.authKey,
      'encryptedVaultKey': wrapVaultKey(vault, nextKeys.wrapKey),
    });
  }

  /// 以当前登录身份调用服务端接口；登录失效（401）时自动退出登录
  static Future<dynamic> request(String path, {String method = 'GET', Object? body}) async {
    if (!loggedIn) throw CloudException('该功能需要登录后使用');
    final uri = Uri.parse('$serverUrl$path');
    final headers = {'Content-Type': 'application/json', 'Authorization': 'Bearer $_token'};
    final res = await _send(() => method == 'GET'
        ? client.get(uri, headers: headers)
        : client.post(uri, headers: headers, body: body == null ? null : jsonEncode(body)));
    if (res.statusCode == 401) {
      _clearSession();
      throw CloudException('登录已过期，请重新登录');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) throw CloudException(_readError(res));
    if (res.statusCode == 204 || res.bodyBytes.isEmpty) return null;
    return jsonDecode(utf8.decode(res.bodyBytes));
  }
}
