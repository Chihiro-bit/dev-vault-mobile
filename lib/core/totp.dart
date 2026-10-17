/// TOTP（RFC 6238）动态码，与桌面端 totp.ts 一致。支持 base32 密钥或 otpauth://totp/... 链接。
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class TotpConfig {
  TotpConfig(this.secret, this.digits, this.period, this.algorithm, {this.issuer, this.account});
  final Uint8List secret;
  final int digits;
  final int period;
  final Hash algorithm;
  final String? issuer;
  final String? account;
}

const _b32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

Uint8List? base32Decode(String input) {
  final s = input.replaceAll(RegExp(r'[\s-]'), '').replaceAll(RegExp(r'=+$'), '').toUpperCase();
  if (s.isEmpty || RegExp(r'[^A-Z2-7]').hasMatch(s)) return null;
  final out = <int>[];
  var bits = 0;
  var value = 0;
  for (final ch in s.split('')) {
    value = ((value << 5) | _b32.indexOf(ch)) & 0xffffffff;
    bits += 5;
    if (bits >= 8) {
      out.add((value >> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Uint8List.fromList(out);
}

TotpConfig? parseTotp(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;
  var secret = s;
  var digits = 6;
  var period = 30;
  Hash algorithm = sha1;
  String? issuer;
  String? account;

  if (s.toLowerCase().startsWith('otpauth:')) {
    final Uri u;
    try {
      u = Uri.parse(s);
    } catch (_) {
      return null;
    }
    if (u.host.toLowerCase() != 'totp') return null;
    final q = u.queryParameters;
    secret = q['secret'] ?? '';
    digits = int.tryParse(q['digits'] ?? '') ?? 6;
    period = int.tryParse(q['period'] ?? '') ?? 30;
    final alg = (q['algorithm'] ?? 'SHA1').toUpperCase();
    algorithm = alg == 'SHA256' ? sha256 : (alg == 'SHA512' ? sha512 : sha1);
    final label = Uri.decodeComponent(u.path.replaceFirst(RegExp(r'^/+'), ''));
    final parts = label.contains(':') ? label.split(':') : [null, label];
    issuer = q['issuer'] ?? parts[0];
    account = (parts[1] ?? '').isEmpty ? null : parts[1];
  }

  final bytes = base32Decode(secret);
  if (bytes == null || bytes.length < 5 || digits < 6 || digits > 8 || period < 5) return null;
  return TotpConfig(bytes, digits, period, algorithm, issuer: issuer, account: account);
}

String totpCode(TotpConfig cfg, [DateTime? now]) {
  final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final counter = ms ~/ 1000 ~/ cfg.period;
  final msg = ByteData(8)
    ..setUint32(0, counter ~/ 0x100000000)
    ..setUint32(4, counter & 0xffffffff);
  final sig = Hmac(cfg.algorithm, cfg.secret).convert(msg.buffer.asUint8List()).bytes;
  final o = sig.last & 0x0f;
  final bin = ((sig[o] & 0x7f) << 24) | (sig[o + 1] << 16) | (sig[o + 2] << 8) | sig[o + 3];
  var mod = 1;
  for (var i = 0; i < cfg.digits; i++) {
    mod *= 10;
  }
  return (bin % mod).toString().padLeft(cfg.digits, '0');
}

/// 本周期剩余秒数
int totpRemaining(TotpConfig cfg, [DateTime? now]) =>
    cfg.period - ((now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000) % cfg.period;

/// 123456 → 123 456，便于阅读
String formatCode(String code) => code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;
