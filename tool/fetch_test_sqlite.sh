#!/usr/bin/env sh
# 下载官方 SQLite DLL，供 Windows 上运行单元测试（手机端使用 sqlite3_flutter_libs 自带的 SQLite，不需要）
set -e
cd "$(dirname "$0")/../test"
mkdir -p native && cd native
curl -sSL -o sqlite.zip https://www.sqlite.org/2025/sqlite-dll-win-x64-3500400.zip
unzip -o -q sqlite.zip sqlite3.dll
rm sqlite.zip
echo "已下载 test/native/sqlite3.dll"
