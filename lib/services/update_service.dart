import 'dart:convert';
import 'dart:io';

import '../core/constants.dart';

/// 最新 Release 信息。
class UpdateInfo {
  final String version;
  final String notes;
  final String url;
  final DateTime? publishedAt;

  const UpdateInfo({
    required this.version,
    required this.notes,
    required this.url,
    this.publishedAt,
  });
}

/// 版本检查：查询 GitHub Releases，比较版本号并简化更新日志。
class UpdateService {
  UpdateService._();

  static const Duration _timeout = Duration(seconds: 10);

  /// 获取最新 Release；网络或解析失败时抛出异常。
  static Future<UpdateInfo> fetchLatest() async {
    final client = HttpClient();
    client.connectionTimeout = _timeout;
    try {
      final req = await client.getUrl(Uri.parse(AppConstants.releasesApiUrl));
      req.headers.set(HttpHeaders.userAgentHeader, AppConstants.appTag);
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}');
      }
      final text = await res
          .transform(utf8.decoder)
          .join()
          .timeout(_timeout);
      final raw = jsonDecode(text);
      if (raw is! Map) throw const FormatException('响应格式非法');
      final j = Map<String, dynamic>.from(raw);
      final version = (j['tag_name'] as String? ?? '')
          .replaceFirst(RegExp(r'^[vV]'), '');
      if (version.isEmpty) throw const FormatException('tag_name 为空');
      return UpdateInfo(
        version: version,
        notes: summarizeNotes(j['body'] as String? ?? ''),
        url: j['html_url'] as String? ?? AppConstants.releasesUrl,
        publishedAt: DateTime.tryParse(j['published_at'] as String? ?? ''),
      );
    } finally {
      client.close();
    }
  }

  static bool isNewer(String latest, String current) =>
      compareVersions(latest, current) > 0;

  static int compareVersions(String a, String b) {
    final pa = _parts(a);
    final pb = _parts(b);
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) return va.compareTo(vb);
    }
    return 0;
  }

  static List<int> _parts(String version) {
    final cleaned = version
        .trim()
        .replaceFirst(RegExp(r'^[vV]'), '')
        .split(RegExp(r'[-+]'))
        .first
        .trim();
    return cleaned.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  }

  /// 把 Release 正文压缩成简短的纯文本，最多保留 [maxLines] 行 / [maxChars] 字。
  static String summarizeNotes(
    String body, {
    int maxLines = 10,
    int maxChars = 600,
  }) {
    if (body.trim().isEmpty) return '';
    var text = body
        .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    // Markdown 链接只保留文字。
    text = text.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]*\)'),
      (m) => m.group(1) ?? '',
    );
    text = text
        .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
        .replaceAll('**', '')
        .replaceAll('__', '')
        .replaceAll('`', '');

    final lines = text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .take(maxLines)
        .toList();
    var result = lines.join('\n');
    if (result.length > maxChars) {
      result = '${result.substring(0, maxChars)}…';
    }
    return result;
  }
}
