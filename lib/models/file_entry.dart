import 'dart:convert';

/// 一个音乐文件的索引条目。
///
/// 以「相对路径」为唯一身份标识；大小与修改时间用于检测「变更」。
class FileEntry {
  /// 相对映射根目录的路径，统一 `/` 分隔，如 `Album/Artist/song.mp3`。
  final String relativePath;

  /// 文件字节数。
  final int size;

  /// 文件最后修改时间（毫秒时间戳）。
  final int mtimeMs;

  /// 可选 SHA-256，暂为扩展位。
  final String? sha256;

  const FileEntry({
    required this.relativePath,
    required this.size,
    required this.mtimeMs,
    this.sha256,
  });

  // 网络传输使用短字段名以减小报文体积。
  Map<String, dynamic> toJson() => {
        'p': relativePath,
        's': size,
        'm': mtimeMs,
        if (sha256 != null) 'h': sha256,
      };

  factory FileEntry.fromJson(Map<String, dynamic> j) => FileEntry(
        relativePath: _str(j, ['p', 'path', 'relativePath']),
        size: _int(j, ['s', 'size']),
        mtimeMs: _int(j, ['m', 'mtimeMs']),
        sha256: _nullableStr(j, ['h', 'sha256']),
      );

  static String _str(Map<String, dynamic> j, List<String> keys) =>
      keys.map((k) => j[k]).firstWhere((v) => v is String, orElse: () => '') as String;

  static int _int(Map<String, dynamic> j, List<String> keys) =>
      keys.map((k) => j[k]).firstWhere((v) => v is num, orElse: () => 0) as int;

  static String? _nullableStr(Map<String, dynamic> j, List<String> keys) {
    for (final k in keys) {
      final v = j[k];
      if (v is String) return v;
    }
    return null;
  }

  /// 判断两个条目是否「内容已变更」（路径相同但大小或时间不同）。
  bool sameContentAs(FileEntry other) => size == other.size && mtimeMs == other.mtimeMs;

  @override
  String toString() => 'FileEntry($relativePath, $size B)';

  static String encodeList(List<FileEntry> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());

  static List<FileEntry> decodeList(String raw) {
    final data = jsonDecode(raw) as List<dynamic>;
    return data
        .map((e) => FileEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}
