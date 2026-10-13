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

  // 设置应用显示名称为 MySend。
  content = content.replaceFirst(RegExp('android:label="[^"]*"'), 'android:label="MySend"');

  file.writeAsStringSync(content);
  stdout.writeln('AndroidManifest 补丁完成');
}