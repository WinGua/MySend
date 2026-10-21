import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mysend/core/utils.dart';
import 'package:mysend/models/file_entry.dart';
import 'package:mysend/models/sync_mapping.dart';
import 'package:mysend/services/sync_engine.dart';
import 'package:mysend/services/transfer/part_store.dart';

void main() {
  group('isValidRelPath', () {
    test('接受普通相对路径', () {
      expect(isValidRelPath('Album/song.mp3'), isTrue);
      expect(isValidRelPath('a/b/c.txt'), isTrue);
    });

    test('拒绝绝对路径、反斜杠与穿越段', () {
      expect(isValidRelPath(''), isFalse);
      expect(isValidRelPath('/etc/passwd'), isFalse);
      expect(isValidRelPath(r'a\b'), isFalse);
      expect(isValidRelPath('../secret'), isFalse);
      expect(isValidRelPath('a/../b'), isFalse);
      expect(isValidRelPath('a//b'), isFalse);
      expect(isValidRelPath('C:/x'), isFalse);
    });

    test('拒绝分片目录本身', () {
      expect(isValidRelPath('.mysend-part/x.part'), isFalse);
    });
  });

  group('SyncEngine.computePlan', () {
    const mapping = SyncMapping(
      id: 'm1',
      name: 'Album',
      sourcePath: '/source',
      destPath: '/dest',
    );

    test('只保留目标端不存在的新增文件', () {
      const source = <String, FileEntry>{
        'a.mp3': FileEntry(relativePath: 'a.mp3', size: 10, mtimeMs: 1),
        'b.mp3': FileEntry(relativePath: 'b.mp3', size: 20, mtimeMs: 2),
      };
      const dest = <String, FileEntry>{
        'a.mp3': FileEntry(relativePath: 'a.mp3', size: 10, mtimeMs: 1),
      };

      final plan = SyncEngine.computePlan(
        mapping: mapping,
        source: source,
        dest: dest,
      );

      expect(plan.toSend.map((e) => e.relativePath), ['b.mp3']);
      expect(plan.totalBytes, 20);
      expect(plan.isEmpty, isFalse);
    });

    test('两端一致时计划为空', () {
      const source = <String, FileEntry>{
        'a.mp3': FileEntry(relativePath: 'a.mp3', size: 10, mtimeMs: 1),
      };
      final plan = SyncEngine.computePlan(
        mapping: mapping,
        source: source,
        dest: source,
      );
      expect(plan.isEmpty, isTrue);
    });
  });

  group('PartStore.currentOffset', () {
    test('元数据一致时按分片长度续传，不一致时丢弃', () async {
      final dir = await Directory.systemTemp.createTemp('mysend_part_test_');
      try {
        const rel = 'Album/a.mp3';
        const meta = PartMeta(path: rel, size: 10, mtime: 1000);
        await PartStore.writeMeta(dir.path, rel, meta);

        final part = PartStore.partFile(dir.path, rel);
        await part.parent.create(recursive: true);
        await part.writeAsBytes(List<int>.filled(4, 0));

        expect(await PartStore.currentOffset(dir.path, rel, 10, 1000), 4);

        // 修改时间变化视为文件已变，分片应被清理并从头开始。
        expect(await PartStore.currentOffset(dir.path, rel, 10, 2000), 0);
        expect(await part.exists(), isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('没有元数据时清理孤立分片', () async {
      final dir = await Directory.systemTemp.createTemp('mysend_part_test_');
      try {
        const rel = 'orphan.bin';
        final part = PartStore.partFile(dir.path, rel);
        await part.parent.create(recursive: true);
        await part.writeAsBytes(List<int>.filled(6, 0));

        expect(await PartStore.currentOffset(dir.path, rel, 6, 1), 0);
        expect(await part.exists(), isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
