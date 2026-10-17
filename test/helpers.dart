import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:devvault_mobile/core/db.dart';
import 'package:devvault_mobile/core/local_crypto.dart';
import 'package:sqlite3/open.dart';

/// 在电脑上跑单元测试。
/// Windows 自带的 winsqlite3 禁用了 localtime（datetime('now','localtime') 返回 NULL），
/// 需要先运行 tool/fetch_test_sqlite.sh 下载官方 sqlite3.dll 到 test/native/。
void setUpTestDb() {
  if (Platform.isWindows) {
    final dll = File('test/native/sqlite3.dll');
    if (!dll.existsSync()) throw StateError('缺少 test/native/sqlite3.dll，请先运行 tool/fetch_test_sqlite.sh');
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(dll.absolute.path));
  }
  LocalCrypto.initWithKey(Uint8List.fromList(List.filled(32, 1)));
  Db.openInMemory();
}
