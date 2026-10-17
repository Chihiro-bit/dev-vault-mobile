# DevVault 手机版

[DevVault](../dev-vault) 的 Flutter 手机客户端：随身查看测试账号、一键复制密码 / 验证码 / TOTP 动态码，管理待办，并通过端到端加密的云同步与桌面端互通。

## 功能

- **账号**：按项目、分类筛选和搜索；一键复制密码（60 秒后自动清除剪贴板）；TOTP 动态码实时刷新；敏感附加字段默认隐藏；有效期提醒；新增 / 编辑 / 收藏 / 删除
- **待办**：未完成 / 已完成列表，勾选完成，快速添加；详情页修改状态、优先级、项目、开始 / 截止日期、提醒时间、重复规则、标签、描述；子任务；进展记录；重复任务完成后自动生成下一次
- **云同步**：登录 / 注册 / 修改主密码 / 退出；修改后 3 秒自动同步，前台每 2 分钟同步一次，回到前台时立即同步
- **安全**：敏感字段用存放在系统安全存储（Android Keystore / iOS Keychain）中的密钥加密；可选应用锁（指纹 / 面容 / 锁屏密码，离开超过 30 秒需重新验证）
- **项目管理**；优先级与状态在桌面端配置，自动同步到手机

## 与桌面端的兼容

手机端是同步协议的另一个客户端，**服务端不需要任何改动**。为了两端行为一致，核心逻辑是逐段对照桌面端移植的：

| 手机端 | 对应桌面端 | 说明 |
| --- | --- | --- |
| `lib/core/e2ee.dart` | `src/main/e2ee.ts` | scrypt → HKDF → AES-256-GCM，逐字节兼容 |
| `lib/core/db.dart` | `src/main/db.ts` | 迁移 V1~V7 完全相同，含同步触发器和内置优先级 / 状态的固定 uid |
| `lib/core/sync.dart` | `src/main/sync.ts` | 拉取 → 合并 → 推送，后写者胜、删除优先 |
| `lib/core/repo.dart` | `src/main/repo.ts` | 待办状态切换、重复任务、清理已完成等规则 |
| `lib/core/totp.dart` | `src/renderer/src/totp.ts` | RFC 6238 |

注意 scrypt 之前要对密码做 NFKC 规范化（`unorm_dart`），否则含全角字符的主密码在两端会派生出不同的密钥。

## 开发

需要 Flutter 3.22+（Dart 3.4+）。

```bash
flutter pub get
flutter run
```

Android 最低支持 6.0（API 23）。iOS 工程已配置面容 ID 说明和 ATS，但尚未在真机上验证。

### 测试

```bash
# Windows 上先下载官方 SQLite DLL（系统自带的 winsqlite3 禁用了 localtime）
sh tool/fetch_test_sqlite.sh

# 单元测试：加密（含桌面端生成的测试向量）、数据库迁移、业务规则、TOTP
flutter test

# 连接真实服务端的同步测试：两个本地数据库模拟两台设备
DEVVAULT_TEST_SERVER=http://127.0.0.1:8080 flutter test test/sync_integration_test.dart

# 真机 / 模拟器端到端测试（账号需事先由桌面端上传过数据，见文件头注释）
adb reverse tcp:8080 tcp:8080
flutter test integration_test/sync_flow_test.dart -d <设备> \
  --dart-define=SERVER=http://127.0.0.1:8080 --dart-define=USER=xxx --dart-define=PASSWORD=xxx
```

`test/fixtures/e2ee_vectors.json` 由桌面端的 `e2ee.ts` 生成，用于保证两端加密互通。

### 发布

`android/app/build.gradle` 的 release 目前使用 debug 签名，正式发布前需要配置自己的签名。

## 暂未支持

- 系统通知提醒（待办的提醒时间会同步，但手机端暂不弹通知）
- 附件（桌面端附件本身也不参与同步）
- 在手机上编辑优先级与状态的配置
- 数据导入 / 导出
- 应用图标仍是 Flutter 默认图标
