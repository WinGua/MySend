/// 一组「目录 → 目录」的映射。
///
/// - [name]：配对键 + 显示名，两端必须一致才能对上（如 `Chinese`）。
/// - [sourcePath]：电脑端本机目录。
/// - [destPath]：安卓端本机目录。
///
/// 双向同步后两端都只读写各自的本机目录，方向由哪一端存在新增文件决定。
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

  /// 本机在该映射中的根目录：电脑端用 [sourcePath]，安卓端用 [destPath]。
  ///
  /// 双向同步时两端都会读写这个目录，不再区分「发送目录 / 接收目录」。
  String localRoot(bool sender) => sender ? sourcePath : destPath;
}