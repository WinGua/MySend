import 'dart:async';
import 'dart:io';

/// 测试用双向 TCP 转发，每次转发数据前注入固定延迟，模拟有延迟的局域网。
/// 它不是带宽模拟器；只用来比较两种实现对请求往返次数的敏感程度。
class DelayedTransferLink {
  final ServerSocket listener;
  final Set<Socket> _sockets = {};
  final Duration delay;
  final int? maxChunkBytes;

  DelayedTransferLink._(this.listener, this.delay, this.maxChunkBytes);

  int get port => listener.port;

  static Future<DelayedTransferLink> start(int targetPort,
      {int? maxChunkBytes}) async {
    final listener = await ServerSocket.bind('127.0.0.1', 0);
    final link = DelayedTransferLink._(
        listener, const Duration(milliseconds: 10), maxChunkBytes);
    listener.listen((incoming) async {
      link._sockets.add(incoming);
      try {
        final outgoing = await Socket.connect('127.0.0.1', targetPort);
        link._sockets.add(outgoing);
        incoming.setOption(SocketOption.tcpNoDelay, true);
        outgoing.setOption(SocketOption.tcpNoDelay, true);
        unawaited(link._forward(incoming, outgoing));
        unawaited(link._forward(outgoing, incoming));
      } catch (_) {
        incoming.destroy();
      }
    });
    return link;
  }

  Future<void> _forward(Socket source, Socket target) async {
    try {
      await for (final bytes in source) {
        final step = maxChunkBytes ?? bytes.length;
        for (var offset = 0; offset < bytes.length; offset += step) {
          await Future<void>.delayed(delay);
          target.add(
              bytes.sublist(offset, (offset + step).clamp(0, bytes.length)));
          await target.flush();
        }
      }
    } catch (_) {
      // 测试结束时连接会被显式销毁。
    } finally {
      source.destroy();
      target.destroy();
      _sockets.remove(source);
      _sockets.remove(target);
    }
  }

  Future<void> close() async {
    await listener.close();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
  }
}
