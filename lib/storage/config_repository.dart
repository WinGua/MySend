import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../core/utils.dart';
import '../models/sync_mapping.dart';

/// 应用配置，持久化为本地 JSON 文件。
class AppConfig {
  String deviceId;
  String deviceName;
  int transferPort;
  bool syncChangedFiles; // 是否同时同步「变更」的文件（默认仅新增）

  /// 多组映射。两端通过 [SyncMapping.name] 配对。
  List<SyncMapping> mappings;

  AppConfig({
    required this.deviceId,
    required this.deviceName,
    required this.transferPort,
    required this.syncChangedFiles,
    required this.mappings,
  });

  factory AppConfig.defaults() => AppConfig(
        deviceId: newUuid(),
        deviceName: isWindows ? '我的电脑' : '我的安卓设备',
        transferPort: AppConstants.transferPort,
        syncChangedFiles: false,
        mappings: [],
      );

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'transferPort': transferPort,
        'syncChangedFiles': syncChangedFiles,
        'mappings': mappings.map((m) => m.toJson()).toList(),
      };

  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
        deviceId: j['deviceId'] as String? ?? newUuid(),
        deviceName: j['deviceName'] as String? ?? '未命名设备',
        transferPort: (j['transferPort'] as num?)?.toInt() ?? AppConstants.transferPort,
        syncChangedFiles: j['syncChangedFiles'] as bool? ?? false,
        mappings: (j['mappings'] as List<dynamic>? ?? [])
            .map((e) => SyncMapping.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

/// 配置仓库：负责读取 / 写入本地 JSON 配置，并在变更时通知 UI。
class ConfigRepository extends ChangeNotifier {
  AppConfig _config = AppConfig.defaults();
  bool _loaded = false;

  AppConfig get config => _config;
  bool get loaded => _loaded;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, AppConstants.configFileName));
  }

  Future<void> load() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        final raw = await file.readAsString();
        _config = AppConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {
      // 配置损坏时回退默认值。
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> save() async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(_config.toJson()), flush: true);
    } catch (e) {
      debugPrint('保存配置失败: $e');
    }
  }

  // ---- 变更方法 ----

  void setDeviceName(String name) {
    _config.deviceName = name.trim().isEmpty ? _config.deviceName : name.trim();
    notifyListeners();
    save();
  }

  void setTransferPort(int port) {
    _config.transferPort = port;
    notifyListeners();
    save();
  }

  void setSyncChangedFiles(bool value) {
    _config.syncChangedFiles = value;
    notifyListeners();
    save();
  }

  void addMapping(SyncMapping mapping) {
    _config.mappings.add(mapping);
    notifyListeners();
    save();
  }

  void updateMapping(SyncMapping mapping) {
    final i = _config.mappings.indexWhere((m) => m.id == mapping.id);
    if (i >= 0) _config.mappings[i] = mapping;
    notifyListeners();
    save();
  }

  void removeMapping(String id) {
    _config.mappings.removeWhere((m) => m.id == id);
    notifyListeners();
    save();
  }
}
