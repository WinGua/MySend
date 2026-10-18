import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/utils.dart';
import '../models/device_info.dart';

/// 局域网设备发现服务（基于 UDP 广播）。
///
/// 说明：组播（multicast）在部分 Android 上需要额外的 WifiManager MulticastLock，
/// 且路由器的组播转发行为千差万别。这里改用更稳的 UDP 广播（255.255.255.255，
/// 并额外向每个本机 IPv4 网段的 /24 广播地址发送），对家庭局域网覆盖更可靠；
/// 无法广播到的场景，由「扫码配对」兜底。
class DiscoveryService extends ChangeNotifier {
  final String deviceId;
  final String deviceName;
  final bool isSender;
  final int transferPort;

  final Map<String, PeerDevice> _devices = {};
  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  Timer? _cleanupTimer;

  DiscoveryService({
    required this.deviceId,
    required this.deviceName,
    required this.isSender,
    required this.transferPort,
  });

  /// 当前发现的设备列表，id 为键去重。
  Iterable<PeerDevice> get devices =>
      _devices.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  /// 把「扫码配对」或「连接确认」得到的设备加入列表
  /// （无广播心跳也保留，直至广播接管；[connected] 标记为已连接）。
  void addScanned(PeerDevice d, {bool connected = false}) {
    final existed = _devices[d.id];
    final keep = (existed?.connected ?? false) || connected;
    _devices[d.id] = keep ? d.copyWith(connected: true) : d;
    notifyListeners();
  }

  /// 移除指定设备（断开连接 / 主动删除）。
  void removeDevice(String id) {
    if (_devices.remove(id) != null) notifyListeners();
  }

  bool get running => _socket != null;

  Future<void> start() async {
    if (_socket != null) return;
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        AppConstants.discoveryPort,
        reuseAddress: true,
        reusePort: true,
      );
      _socket!.broadcastEnabled = true;
      _socket!.listen(_onPacket);
      _announce();
      _announceTimer = Timer.periodic(const Duration(seconds: 3), (_) => _announce());

      // 定期清理长时间无心跳的设备。
      _cleanupTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        final now = DateTime.now();
        final expired = _devices.values
            .where((d) => now.difference(d.lastSeen).inSeconds > 15)
            .map((d) => d.id)
            .toList();
        if (expired.isNotEmpty) {
          for (final id in expired) {
            _devices.remove(id);
          }
          notifyListeners();
        }
      });
    } catch (e) {
      debugPrint('发现服务启动失败: $e');
    }
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
    _devices.clear();
    notifyListeners();
  }

  void _onPacket(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket?.receive();
    if (datagram == null) return;
    try {
      final text = utf8.decode(datagram.data);
      final json = jsonDecode(text) as Map<String, dynamic>;
      if (json['t'] != 'hello') return; // 无关报文
      final peer = PeerDevice.fromEnvelope(json, datagram.address.address);
      if (peer.id.isEmpty || peer.id == deviceId) return; // 跳过自己/无效
      // 单向传输（PC→Android）：仅保留对向角色设备，
      // 发送端只显示接收端（手机/平板），接收端只显示发送端（电脑）。
      if (peer.isSender == isSender) return;
      final existed = _devices[peer.id];
      // 已连接状态需跨广播心跳保持，不被后续报文重置。
      _devices[peer.id] = (existed != null && existed.connected)
          ? peer.copyWith(connected: true)
          : peer;
      notifyListeners();
    } catch (_) {
      // 忽略无法解析的报文。
    }
  }

  Future<void> _announce() async {
    final socket = _socket;
    if (socket == null) return;
    final payload = utf8.encode(jsonEncode({
      't': 'hello',
      'id': deviceId,
      'name': deviceName,
      'platform': platformTag,
      'form': deviceForm,
      'sender': isSender,
      'port': transferPort,
    }));

    final targets = <String>{'255.255.255.255'};
    try {
      for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final addr in nic.addresses) {
          final ip = addr.address;
          if (ip == '127.0.0.1') continue;
          // 常见家庭网段按 /24 处理，向网段广播地址发送。
          final parts = ip.split('.');
          if (parts.length == 4) {
            targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
          }
        }
      }
    } catch (_) {}

    for (final target in targets) {
      try {
        socket.send(payload, InternetAddress(target), AppConstants.discoveryPort);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}