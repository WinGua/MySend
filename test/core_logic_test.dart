import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mysend/core/utils.dart';
import 'package:mysend/models/file_entry.dart';
import 'package:mysend/models/sync_mapping.dart';
import 'package:mysend/services/sync_engine.dart';
import 'package:mysend/services/transfer/part_store.dart';
import 'package:mysend/services/transfer/protocol.dart';
import 'package:mysend/services/update_service.dart';

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

  group('SyncEngine.computeBidirectionalPlan', () {
    const mapping = SyncMapping(
      id: 'm1',
      name: 'Album',
      sourcePath: '/source',
      destPath: '/dest',
    );

    test('分别计算发送与接收，并跳过两端都有的文件', () {
      const local = <String, FileEntry>{
        'a.mp3': FileEntry(relativePath: 'a.mp3', size: 10, mtimeMs: 1),
        'b.mp3': FileEntry(relativePath: 'b.mp3', size: 20, mtimeMs: 2),
      };
      const remote = <String, FileEntry>{
        'a.mp3': FileEntry(relativePath: 'a.mp3', size: 10, mtimeMs: 1),
        'c.mp3': FileEntry(relativePath: 'c.mp3', size: 30, mtimeMs: 3),
      };

      final plan = SyncEngine.computeBidirectionalPlan(
        mapping: mapping,
        local: local,
        remote: remote,
      );

      expect(plan.toPush.map((e) => e.relativePath), ['b.mp3']);
      expect(plan.toPull.map((e) => e.relativePath), ['c.mp3']);
      expect(plan.skippedCount, 1);
      expect(plan.pushBytes, 20);
      expect(plan.pullBytes, 30);
      expect(plan.totalCount, 2);
      expect(plan.isEmpty, isFalse);
    });

    test('两端一致时计划为空', () {
      const local = <String, FileEntry>{
        'a.mp3': FileEntry(relativePath: 'a.mp3', size: 10, mtimeMs: 1),
      };
      final plan = SyncEngine.computeBidirectionalPlan(
        mapping: mapping,
        local: local,
        remote: local,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.skippedCount, 1);
    });
  });

  group('SyncLogReport', () {
    test('对端视角写入时互换发送与接收', () {
      final report = SyncLogReport(
        mappingName: 'Album',
        peerName: '手机',
        time: DateTime.fromMillisecondsSinceEpoch(1000),
        sentCount: 2,
        sentBytes: 20,
        sentFiles: const ['a.mp3', 'b.mp3'],
        receivedCount: 1,
        receivedBytes: 5,
        receivedFiles: const ['c.mp3'],
      );

      final mirrored = report.mirrored();
      expect(mirrored.sentFiles, ['c.mp3']);
      expect(mirrored.receivedFiles, ['a.mp3', 'b.mp3']);
      expect(mirrored.sentBytes, 5);
      expect(mirrored.receivedBytes, 20);
    });
  });

  group('UpdateService', () {
    test('版本比较', () {
      expect(UpdateService.isNewer('1.2.0', '1.1.9'), isTrue);
      expect(UpdateService.isNewer('v1.0.1', '1.0.0'), isTrue);
      expect(UpdateService.isNewer('1.0.0', '1.0.0'), isFalse);
      expect(UpdateService.compareVersions('1.0', '1.0.0'), 0);
    });

    test('更新日志去掉 Markdown 标记并限制行数', () {
      final notes = UpdateService.summarizeNotes(
        '### 更新内容\n\n**新增** 双向同步\n- 日志改造\n- [链接](https://example.com)',
      );
      expect(notes.contains('###'), isFalse);
      expect(notes.contains('**'), isFalse);
      expect(notes.contains('https://example.com'), isFalse);
      expect(notes.contains('双向同步'), isTrue);
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
