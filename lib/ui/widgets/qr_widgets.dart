import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app_scope.dart';
import '../../core/constants.dart';
import '../../core/utils.dart';
import 'glass.dart';

/// 构造配对二维码的内容：`mysend://pair?ip=...&...`。
String buildPairUri(Map<String, dynamic> self, String ip) {
  final uri = Uri(
    scheme: AppConstants.pairScheme,
    host: AppConstants.pairHost,
    queryParameters: {
      'ip': ip,
      'port': '${self['port']}',
      'id': '${self['id']}',
      'name': '${self['name']}',
      'platform': '${self['platform']}',
      'form': '${self['form']}',
      'sender': self['sender'] == true ? '1' : '0',
    },
  );
  return uri.toString();
}

/// 解析扫码得到的配对内容；非法或非本应用 scheme 返回 null。
Map<String, dynamic>? parsePairUri(String raw) {
  try {
    final uri = Uri.parse(raw);
    if (uri.scheme != AppConstants.pairScheme) return null;
    final q = uri.queryParameters;
    final ip = q['ip'];
    if (ip == null || ip.isEmpty) return null;
    return <String, dynamic>{
      'ip': ip,
      'id': q['id'] ?? '',
      'name': q['name'] ?? '',
      'platform': q['platform'] ?? 'other',
      'form': q['form'] ?? 'other',
      'sender': q['sender'] == '1',
      'port': int.tryParse(q['port'] ?? '') ?? AppConstants.transferPort,
    };
  } catch (_) {
    return null;
  }
}

/// 电脑端「创建连接二维码」弹窗：展示本机配对二维码与 IP:端口。
class QrPairDialog extends StatefulWidget {
  const QrPairDialog({super.key});

  @override
  State<QrPairDialog> createState() => _QrPairDialogState();
}

class _QrPairDialogState extends State<QrPairDialog> {
  String? _ip;
  String? _uri;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ip = await localIpv4Address();
    if (ip != null && mounted) {
      setState(() {
        _ip = ip;
        _uri = buildPairUri(scope.selfDescribe(), ip);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final uri = _uri;
    return GlassDialog(
      title: '创建连接二维码',
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '用手机端「扫码添加设备」扫描此二维码，即可发起连接。',
              style: TextStyle(fontSize: 13, color: Color(0xFFc0c0c0)),
            ),
            const SizedBox(height: 16),
            if (uri == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('未能获取本机 IP，请确认已连接局域网。'),
              )
            else ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Color(0xFFFFFFFF),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: uri!,
                  version: QrVersions.auto,
                  size: 220,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '本机地址 $_ip:${scope.config.config.transferPort}',
                style: const TextStyle(fontSize: 13, color: Color(0xFFc0c0c0)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          child: const Text('关闭'),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }
}

/// 手机端「扫码添加设备」页面：使用相机扫描，命中后回填结果。
class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    _ensureCamera();
  }

  Future<void> _ensureCamera() async {
    try {
      await Permission.camera.request();
    } catch (_) {}
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final parsed = parsePairUri(raw);
      if (parsed != null) {
        _handled = true;
        Navigator.pop(context, parsed);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: const PageHeader(title: Text('扫码添加设备')),
      content: Stack(
        children: [
          Positioned.fill(child: MobileScanner(onDetect: _onDetect)),
          Positioned(
            left: 0,
            right: 0,
            bottom: 40,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xCC101820),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '对准电脑端「创建连接二维码」进行扫描',
                  style: TextStyle(fontSize: 13, color: Color(0xFFFFFFFF)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}