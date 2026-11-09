# MySend

局域网双向文件同步工具：Windows 电脑与 Android 手机 / 平板之间，按映射**互补新增**文件。
一套 Flutter 代码同时构建 Windows 与 Android 端，两端功能与同步逻辑保持一致。

电脑和手机都可以作为发起方：点击「对比」扫描两端各自的新增文件，点击「同步」时先发送本机新增，
再自动接收对端新增。适合音乐、照片、文档等双向往来的场景。

> 当前版本：**2.0.0**（双向同步）

## 下载

预编译产物由 GitHub Actions 自动构建，并随每次 Release 提供，前往
[Releases](https://github.com/WinGua/MySend/releases) 下载最新版本：

- **Windows（电脑端）**：`MySend-Windows-x64.zip`，解压后运行 `MySend.exe`。
- **Android（手机 / 平板端）**：`MySend-Android.apk`，传到设备侧载安装。

## 特性

- **双向互补**：电脑与 Android 都具备发送和接收能力，任意一端都能发起任务。
- **点击方先发**：同步时先推送本机的独有新增，完成后再自动切换另一端为发送方。
- **只补新增**：两端都存在的相对路径直接跳过，不比对内容。
- **不覆盖、不删除**：不会覆盖对端已有文件，也不会清理任一端多出的文件。
- **多组映射**：可配置任意多组目录映射，两端以映射名称配对，按相对路径对齐，各自选择本机目录。
- **局域网直连与自动发现**：UDP 广播发现同一网络内的设备，一键连接；同一 Wi-Fi 或手机热点均可。
- **双端可发起**：电脑端与 Android 端都能执行「连接 / 对比 / 同步」完整流程。
- **断点续传**：中断、切网或锁屏后可只补传剩余字节。
- **原子落盘**：文件先写入 `.mysend-part` 分片，校验字节数后原子改名，不会留下半截文件。
- **对比结果**：分别展示「将发送」与「将接收」的文件数量与大小。
- **同步进度**：显示总进度、已发送 / 已接收数量与大小、实时速度，以及当前文件方向。
- **同步日志**：按发送 / 接收分列记录任务名、时间、文件数与大小，只保存文件名，保留最近 7 天。
- **启动检查更新**：每次启动自动检查一次；发现新版本时展示简略更新日志与下载入口，也可在设置页手动检查。
- **后台保活**：Android 端使用前台服务，切后台或锁屏不中断接收。
- **安全忽略规则**：隐藏文件、系统文件与 Office 临时文件不参与同步，并对路径做穿越校验。
- **协议兼容**：保持 v2，兼容旧版 MySend 与 SPW-Send 模组。

## 工作原理

1. 发起端扫描本机映射目录，同时拉取对端同名映射的索引（相对路径、大小、修改时间）。
2. 按相对路径逐文件判定方向：
   - 本机有、对端无 → **本机发送**
   - 对端有、本机无 → **本机接收**
   - 两端都有 → **跳过**
3. 点击「同步」后先发送本机新增，再接收对端新增。
4. 文件通过局域网 HTTP 传输：发送走 `/v2/upload`，接收走 `/v2/file` 的 HTTP Range。
   每个文件先写入本机目录下的 `.mysend-part` 分片，校验字节数后原子改名；中断后按分片偏移续传。
5. 配对时双方交换会话 token，后续请求均需携带。当前为明文 HTTP，尚未启用 TLS 加密。

## 同步规则

- 双向能力，但一次任务只由点击同步的一方依次执行「先发后收」。
- 只同步对端不存在的相对路径。
- 不比对内容、不覆盖、不删除。
- 任一路径段以 `.` 开头、以 `~$` 开头，或文件名为 `desktop.ini` / `thumbs.db` / `ehthumbs.db` 时忽略。
- 两端映射名称必须一致；每一端只需要配置自己的本机目录。

## 协议与兼容

传输协议保持 v2，新增能力以增量端点提供：

| 端点 | 作用 |
| --- | --- |
| `GET /v2/index` | 返回本机映射目录索引 |
| `GET /v2/file` | 提供文件下载，支持 Range 续传 |
| `GET /v2/resume` | 查询单文件已接收偏移 |
| `POST /v2/resume/batch` | 批量查询已接收偏移 |
| `POST /v2/upload` | 分片续传上传，原子落盘 |
| `POST /v2/log` | 接收对端同步日志 |
| `POST /v2/disconnect` | 断开配对 |

兼容说明：

- 新电脑 ↔ 旧安卓：可以推送，接收方向会提示升级对端。
- 旧电脑 ↔ 新安卓：可以接收，推送方向会提示升级对端。
- SPW-Send 模组继续使用 `index + upload`，不受影响。
- 同一台电脑上 MySend 与 SPW-Send 模组都监听 `53318`，不能同时运行。

## 技术栈

- Flutter（stable 渠道）
- [fluent_ui](https://pub.dev/packages/fluent_ui)
- [window_manager](https://pub.dev/packages/window_manager) + [flutter_acrylic](https://pub.dev/packages/flutter_acrylic)（Windows 窗口）
- [file_picker](https://pub.dev/packages/file_picker) / [permission_handler](https://pub.dev/packages/permission_handler) / [path_provider](https://pub.dev/packages/path_provider)（目录、权限与存储）
- [wakelock_plus](https://pub.dev/packages/wakelock_plus)（同步期间唤醒锁）
- [crypto](https://pub.dev/packages/crypto) / [uuid](https://pub.dev/packages/uuid) / [url_launcher](https://pub.dev/packages/url_launcher)

## 目录结构

```
MySend/
├── lib/
│   ├── main.dart                  # 入口：窗口 / 服务初始化
│   ├── app.dart / app_scope.dart  # App 与全局服务容器
│   ├── core/                      # 常量、工具
│   ├── models/                    # 映射、文件条目、设备、双向同步计划
│   ├── storage/                   # 配置与同步日志持久化（JSON）
│   ├── services/
│   │   ├── discovery_service.dart      # 局域网发现（UDP 广播）
│   │   ├── local_index_service.dart    # 本地索引扫描
│   │   ├── sync_engine.dart            # 双向差异计算与传输
│   │   ├── update_service.dart         # 版本检查与更新日志简化
│   │   └── transfer/
│   │       ├── local_transfer_server.dart  # 两端统一的 HTTP 服务
│   │       ├── peer_client.dart            # 协议客户端
│   │       ├── protocol.dart               # 协议常量与日志报文
│   │       └── part_store.dart             # 分片续传与原子落盘
│   ├── platform/                  # 权限、目录选择
│   └── ui/                        # 导航、页面与通用组件
├── android/                       # Android 原生工程（含权限/签名配置）
├── windows/                       # Windows 原生工程（产物名 MySend）
├── .github/workflows/             # CI 构建脚本
└── pubspec.yaml
```

## 使用说明

1. 两端安装并启动 MySend，确保连接同一 Wi-Fi，或让电脑连接手机热点。
2. 在「映射」页新增映射，名称两端保持一致，各自选择本机目录。
3. 在「状态」页连接对端设备。
4. 点击映射的「对比」，查看「将发送」与「将接收」的文件。
5. 点击「同步」：先发送本机新增，再接收对端新增。

> 安卓端首次选择目录会请求「所有文件访问」权限，授权后才能直接写入真实路径。

### 更新

- 每次启动会自动检查一次；无更新或网络异常时静默跳过。
- 设置页「检查更新」可手动比对，并展示版本、简略更新日志与下载入口。

## 已知限制

- **传输为局域网明文 HTTP**，未加密，仅建议在可信网络内使用。
- **Windows 可执行文件未签名**，首次运行可能触发 SmartScreen，选择「更多信息 → 仍要运行」。
- **APK 使用固定 release 签名**：自 v1.0.0 起包名统一为 `com.wingua.mysend`，
  `1.x` 与 `2.x` 可覆盖升级；更早的 `com.example.music_sync` 需要卸载后重装。
- **Android 端需要「所有文件访问」权限**才能直接写入真实目录；如需上架 Google Play，需要改用 SAF。
- **后台保活**依赖前台服务常驻通知；Android 15+ 对 `dataSync` 前台服务有每日时长上限。
- 少数国产系统（如 vivo OriginOS）对全屏 / 挖孔区域有系统级限制，可能需要在系统设置中调整顶部显示。
- 一次同步由点击方执行；两端同时点击同步没有互斥保护，可能造成重复传输。
- 不覆盖、不删除、不比对文件内容；需要这些能力时请自行手动处理。

## 开发声明

本项目为 **Built by Winter with DeepSeek**。开发过程由 AI 辅助并经过多轮代码检查与真机测试，
但仍可能存在尚未发现的问题、边界情况或设计不足。使用时如遇到 bug，欢迎提交 Issue；
也欢迎发起 Pull Request 共同改进。
