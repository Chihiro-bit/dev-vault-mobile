/// 端到端加密，与桌面端 src/main/e2ee.ts 逐字节兼容（协议见桌面端 docs/server-api.md）。
///
///   主密码 ──scrypt(salt)──► masterKey ─┬─HKDF("auth")─► authKey   发给服务端用于登录
///                                       └─HKDF("wrap")─► wrapKey   在本机包裹 / 解开数据密钥
///   vaultKey：注册时随机生成的 256 位数据密钥，每条同步记录用它做 AES-256-GCM 加密，
///             AAD 绑定记录类型与 id，防止密文被挪用到其他记录。
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:pointycastle/export.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

class KdfParams {
  const KdfParams({required this.n, required this.r, required this.p, required this.salt});

  final int n;
  final int r;
  final int p;

  /// base64
  final String salt;

  /// N=2^17、r=8 约需 128MB 内存，与桌面端保持一致（参数改小会导致已有账号无法登录）
  factory KdfParams.generate() => KdfParams(n: 1 << 17, r: 8, p: 1, salt: base64.encode(randomBytes(16)));

  factory KdfParams.fromJson(Map<String, dynamic> j) {
    if (j['type'] != 'scrypt') throw E2eeException('不支持的密钥派生算法：${j['type']}');
    return KdfParams(n: j['n'] as int, r: j['r'] as int, p: j['p'] as int, salt: j['salt'] as String);
  }

  Map<String, dynamic> toJson() => {'type': 'scrypt', 'n': n, 'r': r, 'p': p, 'salt': salt};
}

class E2eeException implements Exception {
  E2eeException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DerivedKeys {
  DerivedKeys(this.authKey, this.wrapKey);

  /// base64，提交给服务端
  final String authKey;
  final Uint8List wrapKey;
}

final _rng = Random.secure();

Uint8List randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

const _version = 'v1.';
const _vaultKeyAad = 'devvault/vault-key';

/// 在后台 isolate 中派生密钥，scrypt 计算期间界面不卡顿
Future<DerivedKeys> deriveKeys(String password, KdfParams kdf) {
  // 服务端可调整参数，但客户端仍设上限，防止被恶意服务器用超大参数拖垮
  if (kdf.n > 1 << 20 || kdf.r > 32 || kdf.p > 16) throw E2eeException('服务器返回的密钥参数异常');
  return Isolate.run(() => deriveKeysSync(password, kdf));
}

DerivedKeys deriveKeysSync(String password, KdfParams kdf) {
  final pwd = utf8.encode(unorm.nfkc(password));
  final master = scrypt(pwd, base64.decode(kdf.salt), kdf.n, kdf.r, kdf.p, 32);
  final keys = DerivedKeys(
    base64.encode(hkdfSha256(master, 'devvault/auth/v1', 32)),
    hkdfSha256(master, 'devvault/wrap/v1', 32),
  );
  master.fillRange(0, master.length, 0);
  return keys;
}

// ---------- AES-256-GCM ----------

String _seal(Uint8List key, List<int> plain, String aad) {
  final iv = randomBytes(12);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List.fromList(utf8.encode(aad))));
  final body = cipher.process(Uint8List.fromList(plain)); // ciphertext ‖ tag
  return _version + base64.encode([...iv, ...body]);
}

Uint8List _open(Uint8List key, String sealed, String aad) {
  if (!sealed.startsWith(_version)) throw E2eeException('不支持的密文版本');
  final raw = base64.decode(sealed.substring(_version.length));
  if (raw.length < 28) throw E2eeException('密文已损坏');
  final cipher = GCMBlockCipher(AESEngine())
    ..init(false, AEADParameters(KeyParameter(key), 128, raw.sublist(0, 12), Uint8List.fromList(utf8.encode(aad))));
  try {
    return cipher.process(raw.sublist(12));
  } on InvalidCipherTextException {
    throw E2eeException('密文校验失败');
  }
}

Uint8List newVaultKey() => randomBytes(32);

String wrapVaultKey(Uint8List vaultKey, Uint8List wrapKey) => _seal(wrapKey, vaultKey, _vaultKeyAad);

Uint8List unwrapVaultKey(String wrapped, Uint8List wrapKey) {
  try {
    final key = _open(wrapKey, wrapped, _vaultKeyAad);
    if (key.length != 32) throw E2eeException('');
    return key;
  } catch (_) {
    throw E2eeException('无法解开数据密钥，请确认密码正确');
  }
}

String _recordAad(String kind, String id) => 'devvault/record/$kind/$id';

String encryptRecord(Uint8List vaultKey, String kind, String id, Object? data) =>
    _seal(vaultKey, utf8.encode(jsonEncode(data)), _recordAad(kind, id));

dynamic decryptRecord(Uint8List vaultKey, String kind, String id, String payload) =>
    jsonDecode(utf8.decode(_open(vaultKey, payload, _recordAad(kind, id))));

// ---------- HKDF / PBKDF2 / scrypt ----------

/// HKDF-SHA256，salt 为空（等价于 32 字节 0），与 Node 的 hkdfSync(…, Buffer.alloc(0), …) 一致
Uint8List hkdfSha256(List<int> ikm, String info, int length) {
  final prk = c.Hmac(c.sha256, Uint8List(32)).convert(ikm).bytes;
  final out = BytesBuilder();
  var t = <int>[];
  for (var i = 1; out.length < length; i++) {
    t = c.Hmac(c.sha256, prk).convert([...t, ...utf8.encode(info), i]).bytes;
    out.add(t);
  }
  return Uint8List.fromList(out.takeBytes().sublist(0, length));
}

/// 单轮 PBKDF2-HMAC-SHA256（scrypt 只需要 1 轮）
Uint8List _pbkdf2Once(List<int> password, List<int> salt, int length) {
  final hmac = c.Hmac(c.sha256, password);
  final out = Uint8List(length);
  for (var i = 1, off = 0; off < length; i++, off += 32) {
    final block = hmac.convert([...salt, i >> 24 & 0xff, i >> 16 & 0xff, i >> 8 & 0xff, i & 0xff]).bytes;
    out.setRange(off, min(off + 32, length), block);
  }
  return out;
}

/// scrypt（RFC 7914）
Uint8List scrypt(List<int> password, List<int> salt, int n, int r, int p, int dkLen) {
  if (n < 2 || n & (n - 1) != 0) throw E2eeException('scrypt 参数 N 必须是 2 的幂');
  final blockWords = 32 * r;
  final b = _pbkdf2Once(password, salt, p * 128 * r);
  final bd = ByteData.sublistView(b);
  final x = Uint32List(blockWords);
  final y = Uint32List(blockWords);
  final v = Uint32List(blockWords * n);
  final tmp = Uint32List(16);

  for (var i = 0; i < p; i++) {
    final base = i * 128 * r;
    for (var k = 0; k < blockWords; k++) {
      x[k] = bd.getUint32(base + k * 4, Endian.little);
    }
    for (var j = 0; j < n; j++) {
      v.setRange(j * blockWords, (j + 1) * blockWords, x);
      _blockMix(x, y, tmp, r);
    }
    for (var j = 0; j < n; j++) {
      final idx = (x[(2 * r - 1) * 16] & (n - 1)) * blockWords;
      for (var k = 0; k < blockWords; k++) {
        x[k] ^= v[idx + k];
      }
      _blockMix(x, y, tmp, r);
    }
    for (var k = 0; k < blockWords; k++) {
      bd.setUint32(base + k * 4, x[k], Endian.little);
    }
  }
  v.fillRange(0, v.length, 0);
  return _pbkdf2Once(password, b, dkLen);
}

/// BlockMix：结果写回 b，y 为同样大小的临时区
void _blockMix(Uint32List b, Uint32List y, Uint32List t, int r) {
  final last = (2 * r - 1) * 16;
  for (var k = 0; k < 16; k++) {
    t[k] = b[last + k];
  }
  for (var i = 0; i < 2 * r; i++) {
    for (var k = 0; k < 16; k++) {
      t[k] ^= b[i * 16 + k];
    }
    _salsa8(t);
    // 偶数块放前半，奇数块放后半
    final dst = (i >> 1) * 16 + (i & 1) * r * 16;
    for (var k = 0; k < 16; k++) {
      y[dst + k] = t[k];
    }
  }
  b.setAll(0, y);
}

int _rotl(int v, int n) => ((v << n) | (v >> (32 - n))) & 0xffffffff;

void _salsa8(Uint32List b) {
  var x0 = b[0], x1 = b[1], x2 = b[2], x3 = b[3], x4 = b[4], x5 = b[5], x6 = b[6], x7 = b[7];
  var x8 = b[8], x9 = b[9], x10 = b[10], x11 = b[11], x12 = b[12], x13 = b[13], x14 = b[14], x15 = b[15];
  for (var i = 0; i < 8; i += 2) {
    x4 ^= _rotl((x0 + x12) & 0xffffffff, 7);
    x8 ^= _rotl((x4 + x0) & 0xffffffff, 9);
    x12 ^= _rotl((x8 + x4) & 0xffffffff, 13);
    x0 ^= _rotl((x12 + x8) & 0xffffffff, 18);
    x9 ^= _rotl((x5 + x1) & 0xffffffff, 7);
    x13 ^= _rotl((x9 + x5) & 0xffffffff, 9);
    x1 ^= _rotl((x13 + x9) & 0xffffffff, 13);
    x5 ^= _rotl((x1 + x13) & 0xffffffff, 18);
    x14 ^= _rotl((x10 + x6) & 0xffffffff, 7);
    x2 ^= _rotl((x14 + x10) & 0xffffffff, 9);
    x6 ^= _rotl((x2 + x14) & 0xffffffff, 13);
    x10 ^= _rotl((x6 + x2) & 0xffffffff, 18);
    x3 ^= _rotl((x15 + x11) & 0xffffffff, 7);
    x7 ^= _rotl((x3 + x15) & 0xffffffff, 9);
    x11 ^= _rotl((x7 + x3) & 0xffffffff, 13);
    x15 ^= _rotl((x11 + x7) & 0xffffffff, 18);
    x1 ^= _rotl((x0 + x3) & 0xffffffff, 7);
    x2 ^= _rotl((x1 + x0) & 0xffffffff, 9);
    x3 ^= _rotl((x2 + x1) & 0xffffffff, 13);
    x0 ^= _rotl((x3 + x2) & 0xffffffff, 18);
    x6 ^= _rotl((x5 + x4) & 0xffffffff, 7);
    x7 ^= _rotl((x6 + x5) & 0xffffffff, 9);
    x4 ^= _rotl((x7 + x6) & 0xffffffff, 13);
    x5 ^= _rotl((x4 + x7) & 0xffffffff, 18);
    x11 ^= _rotl((x10 + x9) & 0xffffffff, 7);
    x8 ^= _rotl((x11 + x10) & 0xffffffff, 9);
    x9 ^= _rotl((x8 + x11) & 0xffffffff, 13);
    x10 ^= _rotl((x9 + x8) & 0xffffffff, 18);
    x12 ^= _rotl((x15 + x14) & 0xffffffff, 7);
    x13 ^= _rotl((x12 + x15) & 0xffffffff, 9);
    x14 ^= _rotl((x13 + x12) & 0xffffffff, 13);
    x15 ^= _rotl((x14 + x13) & 0xffffffff, 18);
  }
  b[0] += x0;
  b[1] += x1;
  b[2] += x2;
  b[3] += x3;
  b[4] += x4;
  b[5] += x5;
  b[6] += x6;
  b[7] += x7;
  b[8] += x8;
  b[9] += x9;
  b[10] += x10;
  b[11] += x11;
  b[12] += x12;
  b[13] += x13;
  b[14] += x14;
  b[15] += x15;
}
