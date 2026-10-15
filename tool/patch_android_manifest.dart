// 云端打包辅助脚本：为 `flutter create` 生成的 AndroidManifest.xml 注入所需权限。
// 用法（在项目根目录）：dart tool/patch_android_manifest.dart
import 'dart:io';

void main() {
  const path = 'android/app/src/main/AndroidManifest.xml';
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('未找到 $path，请先运行 flutter create 生成 android 脚手架');
    exit(1);
  }

  var content = file.readAsStringSync();

  const permissions = '''
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>
    <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE"/>
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29"/>
    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>
''';

  // 1. 在 <application> 之前插入权限声明
  const appMarker = '<application';
  if (!content.contains('MANAGE_EXTERNAL_STORAGE')) {
    final idx = content.indexOf(appMarker);
    if (idx == -1) {
      stderr.writeln('未找到 <application 标记');
      exit(1);
    }
    content = content.replaceFirst(appMarker, '$permissions$appMarker');
  }

  // 1.5 声明可打开的 https 链接（用于「GitHub 仓库」「检查更新」跳转）。
  if (!content.contains('<queries>')) {
    const queries = '''
    <queries>
        <intent>
            <action android:name="android.intent.action.VIEW"/>
            <data android:scheme="https"/>
        </intent>
    </queries>
''';
    final qIdx = content.indexOf(appMarker);
    if (qIdx != -1) {
      content = content.replaceFirst(appMarker, '$queries$appMarker');
    }
  }

  // 2. 在 <application> 起始标签的结束 ">" 之前补充 usesCleartextTraffic。
  //    注意：必须在插入权限后重新定位 <application>，否则 appIdx 会落到权限块内。
  if (!content.contains('usesCleartextTraffic')) {
    final start = content.indexOf(appMarker);
    if (start == -1) {
      stderr.writeln('未找到 <application 标记');
      exit(1);
    }
    final gt = content.indexOf('>', start);
    if (gt == -1) {
      stderr.writeln('<application 起始标签缺少 ">"');
      exit(1);
    }
    content = content.replaceRange(gt, gt, ' android:usesCleartextTraffic="true"');
  }

  // 3. 让应用内容延伸到刘海/挖孔区域（shortEdges），避免顶部黑边。
  if (!content.contains('windowLayoutInDisplayCutoutMode')) {
    final actStart = content.indexOf('<activity');
    if (actStart != -1) {
      final actGt = content.indexOf('>', actStart);
      if (actGt != -1) {
        content = content.replaceRange(actGt, actGt, ' android:windowLayoutInDisplayCutoutMode="always"');
      }
    }
  }

  // 4. 设置应用显示名称为 MySend。
  content = content.replaceFirst(RegExp('android:label="[^"]*"'), 'android:label="MySend"');

  file.writeAsStringSync(content);
  stdout.writeln('AndroidManifest 补丁完成');
}