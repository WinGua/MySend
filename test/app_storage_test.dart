import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mysend/storage/app_storage.dart';

void main() {
  test('提权后仍使用原用户目录且只解析一次', () async {
    final root = await Directory.systemTemp.createTemp('mysend_storage_');
    try {
      final storage = AppStorage(
          overridePath: root.path,
          provider: () async => throw StateError('不应切换管理员账户目录'));
      final roots =
          await Future.wait(List.generate(4, (_) => storage.directory));
      expect(roots.map((d) => d.path).toSet(), {root.path});
      expect(await storage.directoryForElevation(), root.path);
      expect(await root.list().toList(), isEmpty);
    } finally {
      await root.delete(recursive: true);
    }
  });
  test('无效目录失败后允许重新尝试，不能缓存成功状态', () async {
    var calls = 0;
    final storage = AppStorage(provider: () async {
      calls++;
      throw const PathAccessException(
          'WinGua', OSError('Access denied', 5), 'Creation failed');
    });
    await expectLater(storage.directory, throwsA(isA<PathAccessException>()));
    await expectLater(storage.directory, throwsA(isA<PathAccessException>()));
    expect(calls, 2);
  });
}
