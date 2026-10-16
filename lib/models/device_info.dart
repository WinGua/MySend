/// 局域网中发现的远端设备（发送端 PC 或接收端 Android）。
class PeerDevice {
  final String id;
  final String name;
  final String platform; // 'windows' | 'android' | 'other'
  final String form; // 'desktop' | 'phone' | 'tablet' | 'other'
  final bool isSender;
  final String address; // IP
  final int port; // HTTP 服务端口
  final DateTime lastSeen;
  final bool connected; // 是否已通过确认建立连接

  const PeerDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.form,
    required this.isSender,
    required this.address,
    required this.port,
    required this.lastSeen,
    this.connected = false,
  });

  factory PeerDevice.fromEnvelope(Map<String, dynamic> e, String sourceAddress) {
    return PeerDevice(
      id: e['id'] as String? ?? '',
      name: e['name'] as String? ?? '未知设备',
      platform: e['platform'] as String? ?? 'other',
      form: e['form'] as String? ?? 'other',
      isSender: (e['sender'] as bool?) ?? false,
      address: sourceAddress,
      port: (e['port'] as num?)?.toInt() ?? 53318,
      lastSeen: DateTime.now(),
    );
  }

  /// 描述自身设备的报文（用于发现广播与配对请求）。
  static Map<String, dynamic> describe({
    required String id,
    required String name,
    required String platform,
    required String form,
    required bool isSender,
    required int port,
  }) =>
      {
        'id': id,
        'name': name,
        'platform': platform,
        'form': form,
        'sender': isSender,
        'port': port,
      };

  PeerDevice copyWith({bool? connected, DateTime? lastSeen}) => PeerDevice(
        id: id,
        name: name,
        platform: platform,
        form: form,
        isSender: isSender,
        address: address,
        port: port,
        lastSeen: lastSeen ?? this.lastSeen,
        connected: connected ?? this.connected,
      );
}