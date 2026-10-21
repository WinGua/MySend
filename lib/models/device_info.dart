import '../core/constants.dart';

/// 局域网中发现的远端设备（PC 或 Android）。
class PeerDevice {
  final String id;
  final String name;

  /// 设备形态：`desktop` / `phone` / `tablet` / `other`（仅用于展示图标）。
  final String form;

  /// 对端本次会话标识；变化说明对端服务已重启，旧 token 需要失效。
  final String session;

  final String address; // IP
  final int port; // HTTP 服务实际端口
  final DateTime lastSeen;
  final bool connected; // 是否已完成配对

  const PeerDevice({
    required this.id,
    required this.name,
    required this.form,
    required this.session,
    required this.address,
    required this.port,
    required this.lastSeen,
    this.connected = false,
  });

  factory PeerDevice.fromHello(Map<String, dynamic> e, String sourceAddress) {
    final role = e['role'] as String? ?? '';
    return PeerDevice(
      id: e['id'] as String? ?? '',
      name: e['name'] as String? ?? '未知设备',
      form: e['form'] as String? ?? (role == 'pc' ? 'desktop' : 'phone'),
      session: e['session'] as String? ?? '',
      address: sourceAddress,
      port: (e['port'] as num?)?.toInt() ?? AppConstants.transferPort,
      lastSeen: DateTime.now(),
    );
  }

  /// 描述自身设备的发现/配对报文（协议 v2 字段）。
  static Map<String, dynamic> describe({
    required String id,
    required String name,
    required String role,
    required String form,
    required int port,
    required String session,
  }) =>
      {
        'proto': AppConstants.protoVersion,
        'id': id,
        'name': name,
        'role': role,
        'form': form,
        'port': port,
        'session': session,
      };

  PeerDevice copyWith({
    bool? connected,
    String? address,
    int? port,
    String? session,
  }) =>
      PeerDevice(
        id: id,
        name: name,
        form: form,
        session: session ?? this.session,
        address: address ?? this.address,
        port: port ?? this.port,
        lastSeen: lastSeen,
        connected: connected ?? this.connected,
      );
}
