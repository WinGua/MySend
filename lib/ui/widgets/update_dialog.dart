import 'package:fluent_ui/fluent_ui.dart';

import '../../core/constants.dart';
import '../../services/update_service.dart';
import 'glass.dart';

/// 更新提示弹窗：版本对比 + 简略更新日志 + 前往下载。
///
/// 返回 true 表示用户选择前往下载。
Future<bool> showUpdatePrompt(BuildContext context, UpdateInfo info) async {
  final go = await showGlassDialog<bool>(
    context: context,
    builder: (ctx) => GlassDialog(
      title: '发现新版本',
      maxWidth: 420,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '当前 v${AppConstants.currentVersion}  →  最新 v${info.version}',
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
          if (info.publishedAt != null) ...[
            const SizedBox(height: 4),
            Text(
              '发布时间 ${_fmtDate(info.publishedAt!)}',
              style: const TextStyle(fontSize: 11, color: Color(0xFF8A8A8A)),
            ),
          ],
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 220),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0x14000000),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              child: Text(
                info.notes.isEmpty ? '该版本未提供更新说明。' : info.notes,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: Color(0xFFB8B8B8),
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        Button(
          child: const Text('稍后'),
          onPressed: () => Navigator.pop(ctx, false),
        ),
        FilledButton(
          child: const Text('前往下载'),
          onPressed: () => Navigator.pop(ctx, true),
        ),
      ],
    ),
  );
  return go == true;
}

String _fmtDate(DateTime t) {
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${pad(t.month)}-${pad(t.day)}';
}
