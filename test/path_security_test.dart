import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mysend/services/local_index_service.dart';
import 'package:mysend/services/transfer/part_store.dart';

Future<void> directoryLink(String target, String link) async {
  if (Platform.isWindows) {
    final result = await Process.run('cmd', [
      '/c',
      'mklink',
      '/J',
      link.replaceAll('/', '\\'),
      target.replaceAll('/', '\\')
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  } else {
    await Link(link).create(target);
  }
}

void main() {
  test('映射内的目录符号链接不能用于访问映射外文件', () async {
    final temp = await Directory.systemTemp.createTemp('mysend_path_security_');
    final root = await Directory('${temp.path}/root').create();
    final outside = await Directory('${temp.path}/private').create();
    await File('${outside.path}/secret.txt').writeAsString('private');
    await directoryLink(outside.path, '${root.path}/escape');
    try {
      expect(
          LocalIndexService.safeFile(root.path, 'escape/secret.txt'), isNull);
      expect(LocalIndexService.safeFile(root.path, 'escape/new.txt'), isNull);
    } finally {
      await temp.delete(recursive: true);
    }
  });
  test('路径校验后替换父目录仍不能越界读写', () async {
    final temp = await Directory.systemTemp.createTemp('mysend_path_race_');
    final root = await Directory('${temp.path}/root').create();
    final child = await Directory('${root.path}/child').create();
    final outside = await Directory('${temp.path}/private').create();
    await File('${child.path}/secret').writeAsString('inside');
    await File('${outside.path}/secret').writeAsString('private');
    final saved = LocalIndexService.safeFile(root.path, 'child/secret')!;
    try {
      await child.rename('${root.path}/old');
      await directoryLink(outside.path, child.path);
      await expectLater(
          saved.readAsString(), throwsA(isA<FileSystemException>()));
      await expectLater(saved.writeAsString('overwrite'),
          throwsA(isA<FileSystemException>()));
      expect(await File('${outside.path}/secret').readAsString(), 'private');
    } finally {
      await temp.delete(recursive: true);
    }
  });
  test('分片目录链接不能写入映射外；落盘不会覆盖并发创建的文件', () async {
    final temp = await Directory.systemTemp.createTemp('mysend_part_security_');
    final root = await Directory('${temp.path}/root').create();
    final outside = await Directory('${temp.path}/private').create();
    try {
      await directoryLink(outside.path, '${root.path}/.mysend-part');
      await expectLater(
          PartStore.writeMeta(root.path, 'file',
              const PartMeta(path: 'file', size: 1, mtime: 0)),
          throwsA(isA<FileSystemException>()));
      expect(await outside.list().isEmpty, isTrue);
      // Removing a directory junction must not recursively touch its destination.
      if (Platform.isWindows) {
        await Process.run('cmd',
            ['/c', 'rmdir', '${root.path}/.mysend-part'.replaceAll('/', '\\')]);
      } else {
        await Link('${root.path}/.mysend-part').delete();
      }
      final part = PartStore.partFile(root.path, 'file');
      await part.writeAsBytes([1, 2, 3]);
      final destination = LocalIndexService.safeFile(root.path, 'file')!;
      expect(await destination.exists(), isFalse);
      await File(destination.path).writeAsString('created concurrently');
      expect(await part.publish('file'), isFalse);
      expect(
          await File(destination.path).readAsString(), 'created concurrently');
      expect(await part.length(), 3);
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
