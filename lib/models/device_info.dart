/// 局域网中发现的远端设备（发送端 PC 或接收端 Android）。
class PeerDevice {
  final String id;
  final String name;
  final String platform; // 'windows' | 'android' | 'other'
  final bool isSender;
  final String address; // IP
  final int port; // 传输服务端口
  final DateTime lastSeen;
  final bool manual; // 是否手动录入的 IP

  const PeerDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.isSender,
    required this.address,
    required this.port,
    required this.lastSeen,
    this.manual = false,
  });

  factory PeerDevice.fromEnvelope(Map<String, dynamic> e, String sourceAddress) {
    return PeerDevice(
      id: e['id'] as String? ?? '',
      name: e['name'] as String? ?? '未知设备',
      platform: e['platform'] as String? ?? 'other',
      isSender: (e['sender'] as bool?) ?? false,
      address: sourceAddress,
      port: (e['port'] as num?)?.toInt() ?? 53318,
      lastSeen: DateTime.now(),
    );
  }
}