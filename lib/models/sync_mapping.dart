import 'dart:convert';

/// 一组「子目录 → 子目录」的映射。
///
/// - [name]：配对键 + 显示名，两端必须一致才能对上（如 `Chinese`）。
/// - [sourcePath]：PC 发送端的绝对目录。
/// - [destPath]：Android 接收端的绝对目录。
class SyncMapping {
  final String id;
  final String name;
  final String sourcePath;
  final String destPath;

  const SyncMapping({
    required this.id,
    required this.name,
    required this.sourcePath,
    required this.destPath,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sourcePath': sourcePath,
        'destPath': destPath,
      };

  factory SyncMapping.fromJson(Map<String, dynamic> j) => SyncMapping(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        sourcePath: j['sourcePath'] as String? ?? '',
        destPath: j['destPath'] as String? ?? '',
      );

  SyncMapping copyWith({String? name, String? sourcePath, String? destPath}) =>
      SyncMapping(
        id: id,
        name: name ?? this.name,
        sourcePath: sourcePath ?? this.sourcePath,
        destPath: destPath ?? this.destPath,
      );

  static String encodeList(List<SyncMapping> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());

  static List<SyncMapping> decodeList(String raw) {
    final data = jsonDecode(raw) as List<dynamic>;
    return data
        .map((e) => SyncMapping.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}
