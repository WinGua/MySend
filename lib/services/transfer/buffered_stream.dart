import 'dart:io';
import 'dart:typed_data';

/// 合并 TLS 的小数据块，减少逐块落盘开销。每条流最多保留一个 512 KiB 缓冲，
/// 下游暂停时停止读取，保持背压；剩余不足一块的数据在正常结束时写出。
Stream<List<int>> bufferedTransferStream(Stream<List<int>> source) async* {
  const capacity = 512 * 1024;
  var buffer = Uint8List(capacity);
  var used = 0;
  await for (final chunk in source) {
    var offset = 0;
    while (offset < chunk.length) {
      final available = capacity - used;
      final remaining = chunk.length - offset;
      final take = available < remaining ? available : remaining;
      buffer.setRange(used, used + take, chunk, offset);
      used += take;
      offset += take;
      if (used == capacity) {
        yield buffer;
        buffer = Uint8List(capacity);
        used = 0;
      }
    }
  }
  if (used > 0) yield Uint8List.sublistView(buffer, 0, used);
}

/// 与接收缓冲匹配的大块文件读取，减少每 64 KiB 一次的文件线程往返。
Stream<List<int>> readTransferFile(File file,
    {int start = 0, required int end}) async* {
  final input = await file.open();
  try {
    await input.setPosition(start);
    var remaining = end - start;
    while (remaining > 0) {
      final bytes =
          await input.read(remaining < 512 * 1024 ? remaining : 512 * 1024);
      if (bytes.isEmpty) break;
      remaining -= bytes.length;
      yield bytes;
    }
  } finally {
    await input.close();
  }
}
