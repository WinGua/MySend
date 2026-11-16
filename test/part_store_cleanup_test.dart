import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mysend/services/transfer/part_store.dart';

void main() {
  test('最后一个分片清理后删除空临时目录，其他分片保留', () async {
    final root = await Directory.systemTemp.createTemp('mysend_empty_parts_');
    try {
      for (final name in ['first', 'second']) {
        await PartStore.writeMeta(
            root.path, name, PartMeta(path: name, size: 4, mtime: 1));
        await PartStore.partFile(root.path, name).writeAsBytes([1, 2]);
      }
      final dir = PartStore.partFile(root.path, 'first').parent;
      await PartStore.discard(root.path, 'first');
      expect(await PartStore.partFile(root.path, 'second').exists(), isTrue);
      await PartStore.discard(root.path, 'second');
      expect(await dir.exists(), isFalse);
    } finally {
      await root.delete(recursive: true);
    }
  });
  test('启动清理删除已有的空临时目录', () async {
    final root = await Directory.systemTemp.createTemp('mysend_empty_parts_');
    try {
      final dir = PartStore.partFile(root.path, 'file').parent;
      await dir.create();
      await PartStore.cleanup(root.path);
      expect(await dir.exists(), isFalse);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
