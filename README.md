# 音乐同步（Music Sync）

局域网内把电脑上的音乐库**单向同步**到 Android 手机/平板的桌面应用。
一套 Flutter 代码同时编译为 **Windows 桌面端（发送端）** 和 **Android 端（接收端）**，
UI 统一采用 Windows 11 磨砂玻璃（Mica/Acrylic）风格。

- 方向：`PC → Android`，单向。
- 规则：只同步**新增**文件（可选「同步变更」），**不处理删除**。
- 映射：用户手动配置**多组**「子目录 → 子目录」，两端以「名称」配对。

## 目录结构

```
music-sync/
├── lib/
│   ├── main.dart                  # 入口：窗口 / 服务初始化
│   ├── app.dart / app_scope.dart  # App 与全局服务容器
│   ├── core/                      # 常量、工具
│   ├── models/                    # 映射、文件条目、设备、同步计划
│   ├── storage/                   # 配置持久化（JSON）
│   ├── services/
│   │   ├── discovery_service.dart # 局域网发现（UDP 广播）
│   │   ├── local_index_service.dart # 本地索引扫描
│   │   ├── sync_engine.dart       # 差异计算 + 单向传输
│   │   └── transfer/              # HTTP 发送端 / 接收端
│   ├── platform/                  # 权限、目录选择
│   └── ui/                        # 主题、导航、页面
├── tool/patch_android_manifest.dart # 云端打包时注入 Android 权限
├── .github/workflows/build.yml      # 云端打包（APK + exe）
└── pubspec.yaml
```

## 云端打包（无需本机装 Flutter / Android SDK / VS）

你只需要一个 GitHub 账号，全程在网页上操作：

1. 在 GitHub 新建一个**空仓库**（例如 `music-sync`），不要勾选 README/.gitignore。
2. 本地执行（在 `music-sync` 项目目录内）：
   ```powershell
   git init
   git add .
   git commit -m "init: music sync"
   git branch -M main
   git remote add origin https://github.com/<你的用户名>/music-sync.git
   git push -u origin main
   ```
3. 打开仓库的 **Actions** 标签页，点击 `build` workflow → **Run workflow**（手动触发即可）。
4. 等待两个 job 跑完，在页面下方 **Artifacts** 下载：
   - `music_sync_android` → `app-release.apk`（装到手机）
   - `music_sync_windows` → 解压后运行 `music_sync.exe`（PC）

> 打 tag（`git tag v1.0 && git push --tags`）也会自动触发一次构建。

## 使用说明

### PC（发送端）
1. 运行程序，进入「映射」页「添加映射」，**名称**填一个能对上号的键（如 `中文`、`摇滚`），
   「源目录」点「浏览」选择电脑上的对应文件夹（`C:\Users\OHD\Music\Chinese`）。
2. 保持程序运行，它会自动广播并作为发送端监听。

### Android（接收端）
1. 安装 APK，进入「设置」→「申请文件访问权限」，授予「允许访问所有文件」。
2. 「映射」页添加**同名**的映射，「目标目录」填手机真实路径
   （如 `/storage/emulated/0/Music/中文`）。
3. 回到「状态」页，选中发现的电脑，点每组的「对比」查看差异，再点「同步新增」。

> 两端同名的映射越多越省事；不想同步的目录直接不配即可。

## 已知限制（v1 诚实说明）

- **传输为局域网明文 HTTP**（尚未加 TLS）。参考 LocalSend 的 HTTPS + 证书固定可作为后续强化项。
- **Windows exe 未签名**：在别的电脑第一次运行会弹 SmartScreen，点「更多信息 → 仍要运行」即可。
- **APK 使用 Flutter 默认签名**：个人侧载直接安装即可；若要上架需自签 release key。
- **Android 目标目录用真实路径填写**：依赖「所有文件访问」权限（个人侧载简单），
  若以后要上架 Google Play 需改用 SAF（文件夹选择器授权）。
- **广播发现**在个别路由器下可能失效，可用「手动添加设备」输入 IP 兜底。
- 依赖版本若在云端 `flutter pub get` 报错，微调 `pubspec.yaml` 对应版本号即可。
