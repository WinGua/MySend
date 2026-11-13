<p align="center">
  <img src="assets/icons/source.png" width="110" alt="MySend" />
</p>

<h1 align="center">MySend</h1>

<p align="center">局域网双向文件同步工具：Windows 电脑与 Android 手机 / 平板之间，按映射<strong>互补新增</strong>文件。<br />
一套 Flutter 代码同时构建 Windows 与 Android 端，两端功能与同步逻辑保持一致。</p>

<p align="center">电脑和手机都可以作为发起方：点击「对比」扫描两端各自的新增文件，点击「同步」时先发送本机新增，再自动接收对端新增。适合音乐、照片、文档等双向往来的场景。</p>

<p align="center">
  <a href="https://github.com/WinGua/MySend/releases/latest"><img src="https://img.shields.io/github/v/release/WinGua/MySend?label=release" alt="Release" /></a>
  <img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="License: GPL-3.0" />
  <img src="https://img.shields.io/badge/platform-Windows-0078D6" alt="Platform: Windows" />
  <img src="https://img.shields.io/badge/platform-Android-3DDC84?logo=android&logoColor=white" alt="Platform: Android" />
  <img src="https://img.shields.io/badge/Flutter-3.24-02569B?logo=flutter&logoColor=white" alt="Flutter" />
</p>

> 当前版本：**2.0.0**（双向同步）

## 下载

预编译产物由 GitHub Actions 自动构建，并随每次 Release 提供，前往
[Releases](https://github.com/WinGua/MySend/releases) 下载最新版本：

- **Windows（电脑端）**：`MySend-Windows-x64.zip`，解压后运行 `MySend.exe`。
- **Android（手机 / 平板端）**：`MySend-Android.apk`，传到设备侧载安装。

## 特性

- **双向互补，点击方先发**：任一端都能发起任务，先推送本机独有新增，再接收对端新增。
- **只补新增，不覆盖、不删除**：两端都存在的相对路径直接跳过，不比对内容，也不清理任一端多出的文件。
- **多组映射**：可配置任意多组目录映射，两端按映射名称配对、按相对路径对齐，各自选择本机目录。
- **局域网自动发现**：UDP 广播发现同网设备，一键连接；同一 Wi-Fi 或手机热点均可。
- **断点续传与原子落盘**：先写 `.mysend-part` 分片，校验字节数后原子改名；中断、切网或锁屏后按偏移续传。
- **进度与日志**：实时显示当前文件、总进度、速度与收发数量；日志按发送 / 接收分列，只记录文件名，保留 7 天。
- **后台保活**：Android 端使用前台服务，切后台或锁屏不中断接收。
- **安全忽略**：隐藏文件、系统文件与 Office 临时文件不参与同步，并对路径做穿越校验。
- **协议兼容**：保持 v2，兼容旧版 MySend 与 SPW-Send 模组。

## 工作原理

1. 发起端扫描本机映射目录，并拉取对端同名映射的索引（相对路径、大小、修改时间）。
2. 按相对路径逐文件判定方向：本机有、对端无 → 发送；对端有、本机无 → 接收；两端都有 → 跳过。
3. 点击「同步」后先发送本机新增，再接收对端新增。
4. 传输走局域网 HTTP：发送 `/v2/upload`，接收 `/v2/file`（支持 Range 续传）；配对时双方交换会话 token，后续请求需携带。

> 只同步对端不存在的相对路径，不比对内容、不覆盖、不删除。任一路径段以 `.` 或 `~$` 开头，或文件名为 `desktop.ini` / `thumbs.db` / `ehthumbs.db` 时忽略；两端映射名称必须一致。

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

- 新旧版本混用：可用的单向能力不受影响，缺失的方向会提示升级对端。
- SPW-Send 模组继续使用 `index + upload`，不受影响。
- MySend 与 SPW-Send 模组都监听 `53318`，同一台电脑上不能同时运行。

## 使用说明

1. 两端安装并启动 MySend，确保连接同一 Wi-Fi，或让电脑连接手机热点。
2. 在「映射」页新增映射，名称两端保持一致，各自选择本机目录。
3. 在「状态」页连接对端设备。
4. 点击映射的「对比」，查看「将发送」与「将接收」的文件。
5. 点击「同步」：先发送本机新增，再接收对端新增。

> 安卓端首次选择目录会请求「所有文件访问」权限，授权后才能直接写入真实路径。每次启动会自动检查一次更新，无更新或网络异常时静默跳过；也可在设置页手动检查。

## 技术栈

- Flutter（stable 渠道）+ [fluent_ui](https://pub.dev/packages/fluent_ui)，Windows 端使用 [window_manager](https://pub.dev/packages/window_manager) / [flutter_acrylic](https://pub.dev/packages/flutter_acrylic)。
- 目录与权限：[file_picker](https://pub.dev/packages/file_picker) / [permission_handler](https://pub.dev/packages/permission_handler) / [path_provider](https://pub.dev/packages/path_provider)。
- 其他：`wakelock_plus`、`crypto`、`uuid`、`url_launcher`。

## 目录结构

`lib/` 为 Dart 代码（`services/transfer/` 为协议与传输实现），`android/`、`windows/` 为原生工程，`.github/workflows/` 为 CI 构建脚本。

## 已知限制

- **传输为局域网明文 HTTP**，未加密，仅建议在可信网络内使用。
- **Windows 可执行文件未签名**，首次运行可能触发 SmartScreen，选择「更多信息 → 仍要运行」。
- **APK 使用固定 release 签名**：包名为 `com.wingua.mysend`，`1.x` 与 `2.x` 可覆盖升级；更早的 `com.example.music_sync` 需要卸载后重装。
- **Android 端需要「所有文件访问」权限**才能直接写入真实目录；如需上架 Google Play，需要改用 SAF。
- **后台保活**依赖前台服务常驻通知；Android 15+ 对 `dataSync` 前台服务有每日时长上限。
- 少数国产系统（如 vivo OriginOS）对全屏 / 挖孔区域有系统级限制，可能需要在系统设置中调整顶部显示。
- 一次同步由点击方执行；两端同时点击同步没有互斥保护，可能造成重复传输。

## 开发声明

本项目为 **Built by Winter with DeepSeek**。开发由 AI 辅助并经过多轮检查与真机测试，仍可能存在未发现的问题；欢迎提交 Issue 或 Pull Request 共同改进。
