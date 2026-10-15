// 云端打包辅助脚本：给 android/app/build.gradle 注入固定的 release 签名。
// 背景：默认 `flutter build apk --release` 会回退到 debug 签名，而云端每次的
//       debug 密钥可能不同，导致新旧 APK 签名不一致、无法覆盖安装升级。
//       因此用 GitHub Secrets 中的稳定密钥在构建时签名（仓库不提交密钥）。
// 用法（在项目根目录）：dart tool/patch_android_gradle.dart
import 'dart:io';

void main() {
  final gradleFile = File('android/app/build.gradle');
  if (!gradleFile.existsSync()) {
    stderr.writeln('未找到 android/app/build.gradle，跳过签名补丁');
    exit(1);
  }

  var s = gradleFile.readAsStringSync();

  // 1) release 改用自定义签名（原模板为 signingConfig = signingConfigs.debug）。
  if (s.contains('signingConfig = signingConfigs.debug')) {
    s = s.replaceAll(
        'signingConfig = signingConfigs.debug', 'signingConfig = signingConfigs.release');
  } else if (s.contains('signingConfigs.debug')) {
    s = s.replaceAll('signingConfigs.debug', 'signingConfigs.release');
  }

  // 2) 注入 release 签名配置（密钥路径相对 android/app/ 目录）。
  //    注意：密码不写死在文件里，而是构建时从环境变量读取，避免密钥明文进仓库。
  final signing = '''
    signingConfigs {
        release {
            storeFile file('../../keystore/my-send-release.keystore')
            storePassword System.getenv('ANDROID_KEYSTORE_PASSWORD') ?: ''
            keyAlias 'mysend'
            keyPassword System.getenv('ANDROID_KEYSTORE_PASSWORD') ?: ''
        }
    }
''';

  if (!s.contains('signingConfigs {')) {
    const marker = '    buildTypes {';
    final idx = s.indexOf(marker);
    if (idx != -1) {
      s = s.replaceRange(idx, idx, '$signing\n');
    }
  }

  gradleFile.writeAsStringSync(s);
  stdout.writeln('android/app/build.gradle 签名补丁完成');
}