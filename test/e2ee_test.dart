import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:devvault_mobile/core/e2ee.dart';
import 'package:flutter_test/flutter_test.dart';

/// 测试向量由桌面端 src/main/e2ee.ts 生成，保证两端互通
void main() {
  final vectors = (jsonDecode(File('test/fixtures/e2ee_vectors.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();

  test('scrypt 与 RFC 7914 测试向量一致', () {
    final out = scrypt(utf8.encode('password'), utf8.encode('NaCl'), 1024, 8, 16, 64);
    expect(
      out.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      'fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b373162'
      '2eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640',
    );
  });

  for (final v in vectors) {
    final kdf = KdfParams.fromJson(v['kdf'] as Map<String, dynamic>);
    test('派生密钥与桌面端一致（N=${kdf.n}，${v['password']}）', () {
      final sw = Stopwatch()..start();
      final keys = deriveKeysSync(v['password'] as String, kdf);
      // ignore: avoid_print
      print('  scrypt N=${kdf.n}: ${sw.elapsedMilliseconds} ms');
      expect(keys.authKey, v['authKey']);
      expect(base64.encode(keys.wrapKey), v['wrapKey']);

      final vault = unwrapVaultKey(v['encryptedVaultKey'] as String, keys.wrapKey);
      expect(base64.encode(vault), v['vaultKey']);
      expect(decryptRecord(vault, 'entry', 'abc123', v['payload'] as String), v['record']);
    });
  }

  test('本端加密的数据可以解开，且 AAD 绑定记录', () {
    final key = newVaultKey();
    final sealed = encryptRecord(key, 'todo', 'x1', {'title': '待办'});
    expect(decryptRecord(key, 'todo', 'x1', sealed), {'title': '待办'});
    expect(() => decryptRecord(key, 'todo', 'x2', sealed), throwsA(isA<E2eeException>()));
    final wrap = Uint8List.fromList(List.filled(32, 7));
    expect(unwrapVaultKey(wrapVaultKey(key, wrap), wrap), key);
  });
}
