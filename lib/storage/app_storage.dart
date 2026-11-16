import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../services/windows_privileges.dart';

/// A single data root for config, logs and the TLS identity, including elevated restarts.
class AppStorage {
  static AppStorage current = AppStorage();
  final String? overridePath;
  final Future<Directory> Function() _provider;
  Future<Directory>? _pending;
  String? _attemptedPath;
  AppStorage({this.overridePath, Future<Directory> Function()? provider})
      : _provider = provider ?? getApplicationSupportDirectory;
  static void configure(List<String> args) {
    String? path;
    for (final arg in args) {
      if (arg.startsWith('--data-directory=')) {
        path = arg.substring('--data-directory='.length);
      }
    }
    current = AppStorage(overridePath: path);
  }

  Future<Directory> get directory {
    if (_pending != null) return _pending!;
    late final Future<Directory> future;
    future = _resolve().onError((Object error, StackTrace stack) {
      if (identical(_pending, future)) _pending = null;
      Error.throwWithStackTrace(error, stack);
    });
    _pending = future;
    return future;
  }

  Future<Directory> _resolve() async {
    final path = overridePath;
    if (path != null && (path.isEmpty || !p.isAbsolute(path))) {
      throw const FormatException('数据目录必须为绝对路径');
    }
    final dir = path == null ? await _provider() : Directory(path);
    _attemptedPath = dir.path;
    await dir.create(recursive: true);
    // Verify the actual create/write/delete operations before reporting services ready.
    final probe = File(p.join(dir.path,
        '.mysend-write-$pid-${Random.secure().nextInt(0x100000000)}'));
    await probe.create(exclusive: true);
    try {
      await probe.writeAsBytes([0], flush: true);
    } finally {
      await probe.delete();
    }
    return dir;
  }

  Future<String> directoryForElevation() async =>
      overridePath ??
      _attemptedPath ??
      await WindowsPrivileges.userDataDirectory();
}
