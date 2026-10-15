import 'dart:convert';

/// 一个文件的索引条目。
///
/// 以「相对路径」为唯一身份标识；优先用内容哈希（SHA-256）检测「变更」，
/// 哈希不可用时退回「大小 + 修改时间」。
class FileEntry {
  /// 相对映射根目录的路径，统一 `/` 分隔，如 `Album/Artist/song.mp3`。
  final String relativePath;

  /// 文件字节数。
  final int size;

  /// 文件最后修改时间（毫秒时间戳）。
  final int mtimeMs;

  /// 文件内容 SHA-256（十六进制），用于内容级变更比对。
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

  /// 判断两个条目内容是否一致。
  /// 优先比较 SHA-256 内容哈希（跨文件系统可靠，不受修改时间精度影响）；
  /// 任一方缺少哈希时退回「大小 + 修改时间」（时间带 2 秒容差）。
  bool sameContentAs(FileEntry other) {
    if (sha256 != null && other.sha256 != null) {
      return sha256 == other.sha256;
    }
    return size == other.size && (mtimeMs - other.mtimeMs).abs() <= 2000;
  }

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