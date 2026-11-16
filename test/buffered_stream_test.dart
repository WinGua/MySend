import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mysend/services/transfer/buffered_stream.dart';

void main() {
  test('小 TLS 数据块合并后保持字节顺序与尾部内容', () async {
    final input =
        Uint8List.fromList(List.generate(2 * 512 * 1024 + 17, (i) => i % 251));
    final source = Stream<List<int>>.fromIterable([
      input.sublist(0, 4096),
      input.sublist(4096, 9191),
      input.sublist(9191),
    ]);
    final chunks = await bufferedTransferStream(source).toList();
    expect(chunks.map((e) => e.length), [512 * 1024, 512 * 1024, 17]);
    expect(chunks.expand((e) => e).toList(), input);
  });
  test('大块文件读取遵守续传起点和结束位置', () async {
    final dir = await Directory.systemTemp.createTemp('mysend_read_');
    try {
      final file = File('${dir.path}/source');
      await file.writeAsBytes(List.generate(600123, (i) => i % 251));
      final chunks =
          await readTransferFile(file, start: 11, end: 600000).toList();
      expect(chunks.map((e) => e.length), [524288, 75701]);
      expect(chunks.expand((e) => e),
          List.generate(599989, (i) => (i + 11) % 251));
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
