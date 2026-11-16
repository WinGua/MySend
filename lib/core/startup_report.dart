import 'dart:convert';
import 'dart:io';

/// 仅显式传入 --startup-report 时输出无凭据的启动状态，供原生 release 冒烟测试。
class StartupReport {
  final File file;
  String stage = 'starting';
  Future<void> _writes = Future.value();
  StartupReport(this.file);
  static StartupReport? fromArguments(List<String> args) {
    for (final arg in args) {
      if (arg.startsWith('--startup-report=')) {
        return StartupReport(File(arg.substring('--startup-report='.length)));
      }
    }
    return null;
  }

  void mark(String state, {bool firstFrame = false, String? failure}) {
    final payload = jsonEncode({
      'state': state,
      'stage': stage,
      'firstFrame': firstFrame,
      if (failure != null) 'errorType': failure
    });
    _writes = _writes.then((_) async {
      await file.parent.create(recursive: true);
      await file.writeAsString(payload, flush: true);
    }).catchError((Object error) {
      stderr.writeln('Startup report unavailable: ${error.runtimeType}');
    });
  }
}
