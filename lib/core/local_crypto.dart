import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

import 'e2ee.dart' show randomBytes;

/// 本机敏感字段加密（对应桌面端用 DPAPI 的 crypto.ts）。
/// 密钥随机生成后保存在系统安全存储（Android Keystore / iOS Keychain），数据库文件本身不含密钥。
class LocalCrypto {
  static const _prefix = 'lk1:';
  static const _storageKey = 'devvault.localKey';
  static Uint8List? _key;

  static Future<void> init() async {
    const storage = FlutterSecureStorage();
    var stored = await storage.read(key: _storageKey);
    if (stored == null) {
      stored = base64.encode(randomBytes(32));
      await storage.write(key: _storageKey, value: stored);
    }
    _key = base64.decode(stored);
  }

  /// 测试用：直接指定密钥
  static void initWithKey(Uint8List key) => _key = key;

  static String encrypt(String plain) {
    if (plain.isEmpty) return '';
    final iv = randomBytes(12);
    final cipher = GCMBlockCipher(AESEngine())..init(true, AEADParameters(KeyParameter(_key!), 128, iv, Uint8List(0)));
    return _prefix + base64.encode([...iv, ...cipher.process(Uint8List.fromList(utf8.encode(plain)))]);
  }

  static String decrypt(String? stored) {
    if (stored == null || stored.isEmpty) return '';
    if (!stored.startsWith(_prefix)) return stored;
    try {
      final raw = base64.decode(stored.substring(_prefix.length));
      final cipher = GCMBlockCipher(AESEngine())
        ..init(false, AEADParameters(KeyParameter(_key!), 128, raw.sublist(0, 12), Uint8List(0)));
      return utf8.decode(cipher.process(raw.sublist(12)));
    } catch (_) {
      return '';
    }
  }
}
