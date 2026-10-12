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

  // 在 <application ...> 之前插入权限声明
  final appMarker = '<application';
  final appIdx = content.indexOf(appMarker);
  if (appIdx == -1) {
    stderr.writeln('未找到 <application 标记');
    exit(1);
  }
  if (!content.contains('MANAGE_EXTERNAL_STORAGE')) {
    content = content.replaceFirst(appMarker, '$permissions$appMarker');
  }

  // 在 <application> 起始标签内补充属性
  const appAttrs = 'android:usesCleartextTraffic="true"';
  if (!content.contains('usesCleartextTraffic')) {
    final gt = content.indexOf('>', appIdx);
    if (gt != -1) {
      content = content.replaceRange(gt, gt, ' $appAttrs');
    }
  }

  file.writeAsStringSync(content);
  stdout.writeln('AndroidManifest 补丁完成');
}
