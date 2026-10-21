import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../models/device_info.dart';

/// 局域网设备发现服务（协议 v2，UDP 广播）。
///
/// - 每 2 秒广播一次 hello，12 秒无心跳视为离线
/// - 只接受 `proto == 2` 且角色为对端的设备
/// - 向 255.255.255.255 与每个网卡的定向广播地址各发一份
class DiscoveryService extends ChangeNotifier {
  final String deviceId;
  final String deviceName;
  final bool isSender;
  final String form;
  final int transferPort;
  final String session;

  /// 对端会话变化（服务重启）时回调，用于让旧 token 失效。
  final void Function(String deviceId)? onPeerSessionChanged;

  final Map<String, PeerDevice> _devices = {};
  Set<String> _targets = {'255.255.255.255'};
  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  Timer? _cleanupTimer;
  Timer? _targetTimer;
  bool _resolving = false;

  DiscoveryService({
    required this.deviceId,
    required this.deviceName,
    required this.isSender,
    required this.form,
    required this.transferPort,
    required this.session,
    this.onPeerSessionChanged,
  });

  /// 当前发现的设备列表，按名称排序。
  List<PeerDevice> get devices =>
      _devices.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  bool get running => _socket != null;

  /// 配对成功或被连接后把设备加入列表并标记为已连接。
  ///
  /// 已由 UDP 发现过的设备保留其真实地址与端口，避免配对报文覆盖。
  void addScanned(PeerDevice d, {bool connected = false}) {
    final base = _devices[d.id] ?? d;
    _devices[d.id] = base.copyWith(
      connected: (base.connected || connected),
      session: d.session,
    );
    notifyListeners();
  }

  /// 断开后仅切换连接状态，保留在列表中。
  void markDisconnected(String id) {
    final d = _devices[id];
    if (d == null || !d.connected) return;
    _devices[id] = d.copyWith(connected: false);
    notifyListeners();
  }

  /// 启动 UDP 监听并开始周期广播。
  Future<void> start() async {
    if (_socket != null) return;
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        AppConstants.discoveryPort,
        reuseAddress: true,
      );
      _socket!.broadcastEnabled = true;
      _socket!.listen(_onPacket);
      await _resolveTargets();
      _announce();
      _announceTimer =
          Timer.periodic(const Duration(seconds: 2), (_) => _announce());
      // 切换 Wi-Fi / 开热点后网段会变化，定期重新解析定向广播地址。
      _targetTimer =
          Timer.periodic(const Duration(seconds: 30), (_) => _resolveTargets());
      _cleanupTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        final now = DateTime.now();
        final expired = _devices.values
            .where((d) =>
                now.difference(d.lastSeen) > AppConstants.peerTimeout &&
                !d.connected)
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
    _targetTimer?.cancel();
    _targetTimer = null;
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
      if (json['t'] != 'hello') return;
      if ((json['proto'] as num?)?.toInt() != AppConstants.protoVersion) return;
      final role = json['role'] as String?;
      if (role == (isSender ? 'pc' : 'android')) return; // 只显示对端角色
      final peer = PeerDevice.fromHello(json, datagram.address.address);
      if (peer.id.isEmpty || peer.id == deviceId) return;

      final existed = _devices[peer.id];
      var wasConnected = existed?.connected ?? false;
      if (existed != null &&
          existed.session.isNotEmpty &&
          peer.session.isNotEmpty &&
          existed.session != peer.session) {
        // 对端服务已重启，旧会话失效。
        onPeerSessionChanged?.call(peer.id);
        wasConnected = false;
      }
      _devices[peer.id] =
          wasConnected ? peer.copyWith(connected: true) : peer;
      notifyListeners();
    } catch (_) {
      // 忽略无法解析的报文。
    }
  }

  void _announce() {
    final socket = _socket;
    if (socket == null) return;
    final payload = utf8.encode(jsonEncode({
      't': 'hello',
      'app': AppConstants.appTag,
      'appVersion': AppConstants.currentVersion,
      ...PeerDevice.describe(
        id: deviceId,
        name: deviceName,
        role: isSender ? 'pc' : 'android',
        form: form,
        port: transferPort,
        session: session,
      ),
    }));

    for (final target in _targets) {
      try {
        socket.send(payload, InternetAddress(target), AppConstants.discoveryPort);
      } catch (_) {}
    }
  }

  /// 重新计算全网广播与各网卡定向广播地址；网段变化时丢弃旧地址。
  Future<void> _resolveTargets() async {
    if (_resolving) return;
    _resolving = true;
    try {
      final targets = <String>{'255.255.255.255'};
      for (final nic
          in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final addr in nic.addresses) {
          final ip = addr.address;
          if (ip == '127.0.0.1') continue;
          final parts = ip.split('.');
          if (parts.length == 4) {
            targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
          }
        }
      }
      _targets = targets;
    } catch (_) {
      // 枚举网卡失败时保留上一次的广播目标。
    } finally {
      _resolving = false;
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
