/// 一个文件的索引条目，以「相对路径」为唯一身份标识。
class FileEntry {
  /// 相对映射根目录的路径，统一 `/` 分隔，如 `Album/Artist/song.mp3`。
  final String relativePath;

  /// 文件字节数。
  final int size;

  /// 文件最后修改时间（毫秒时间戳），下载后回写以保持两端一致。
  final int mtimeMs;

  const FileEntry({
    required this.relativePath,
    required this.size,
    required this.mtimeMs,
  });

  // 网络传输使用短字段名以减小报文体积。
  Map<String, dynamic> toJson() => {
        'p': relativePath,
        's': size,
        'm': mtimeMs,
      };

  factory FileEntry.fromJson(Map<String, dynamic> j) => FileEntry(
        relativePath: _str(j, ['p', 'path', 'relativePath']),
        size: _int(j, ['s', 'size']),
        mtimeMs: _int(j, ['m', 'mtimeMs']),
      );

  static String _str(Map<String, dynamic> j, List<String> keys) =>
      keys.map((k) => j[k]).firstWhere((v) => v is String, orElse: () => '') as String;

  static int _int(Map<String, dynamic> j, List<String> keys) =>
      keys.map((k) => j[k]).firstWhere((v) => v is num, orElse: () => 0) as int;

  @override
  String toString() => 'FileEntry($relativePath, $size B)';
}