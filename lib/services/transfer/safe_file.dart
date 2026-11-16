import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

/// Files under a locally configured mapping. Every open is relative to held
/// directory handles and rejects child symlinks, including Windows junctions.
class SafeFile implements File {
  final String root;
  final String relative;
  SafeFile(this.root, this.relative);
  static final _api = _FileApi();
  @override
  String get path => p.join(root, relative);
  @override
  SafeDirectory get parent => SafeDirectory(root, p.dirname(relative));
  @override
  SafeFile get absolute => this;
  @override
  Future<bool> exists() async =>
      _api.path(root, relative, 0, missing: true) >= 0;
  @override
  Future<int> length() async => _api.path(root, relative, 0);
  Future<(int, int)> metadata() async {
    final id = _api.open(root, relative, FileMode.read);
    try {
      return (
        _api.io(id, nullptr, 0, 3, 0, path),
        _api.io(id, nullptr, 0, 4, 0, path)
      );
    } finally {
      _api.close(id);
    }
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      _SafeHandle(_api.open(root, relative, mode), path);
  @override
  IOSink openWrite(
          {FileMode mode = FileMode.write, Encoding encoding = utf8}) =>
      IOSink(_SafeConsumer(_SafeHandle(_api.open(root, relative, mode), path)),
          encoding: encoding);
  @override
  Stream<List<int>> openRead([int? start, int? end]) async* {
    final file = await open();
    try {
      await file.setPosition(start ?? 0);
      var left = (end ?? await file.length()) - (start ?? 0);
      while (left > 0) {
        final bytes = await file.read(left < 512 * 1024 ? left : 512 * 1024);
        if (bytes.isEmpty) break;
        left -= bytes.length;
        yield bytes;
      }
    } finally {
      await file.close();
    }
  }

  @override
  Future<Uint8List> readAsBytes() async {
    // Used for small resume metadata, never for payload files.
    if (await length() > 64 * 1024) {
      throw FileSystemException('Metadata too large', path);
    }
    final result = BytesBuilder();
    await for (final bytes in openRead()) {
      result.add(bytes);
    }
    return result.takeBytes();
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async =>
      encoding.decode(await readAsBytes());
  @override
  Future<File> writeAsBytes(List<int> bytes,
      {FileMode mode = FileMode.write, bool flush = false}) async {
    final sink = openWrite(mode: mode);
    try {
      sink.add(bytes);
      await sink.flush();
    } finally {
      await sink.close();
    }
    return this;
  }

  @override
  Future<File> writeAsString(String contents,
          {FileMode mode = FileMode.write,
          Encoding encoding = utf8,
          bool flush = false}) =>
      writeAsBytes(encoding.encode(contents), mode: mode, flush: flush);
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    if (exclusive) {
      throw UnsupportedError('Exclusive create is not used for parts');
    }
    final handle = await open(mode: FileMode.append);
    await handle.close();
    return this;
  }

  @override
  Future<File> delete({bool recursive = false}) async {
    _api.path(root, relative, 1);
    return this;
  }

  /// Returns false if another program created the destination first.
  Future<bool> publish(String target) async =>
      _api.path(root, relative, 4, target: target, existing: true) != -3;
  @override
  Future<File> rename(String newPath) async {
    final target = p.relative(newPath, from: root);
    if (!await publish(target)) {
      throw FileSystemException('ALREADY_EXISTS', newPath);
    }
    return SafeFile(root, target);
  }

  @override
  Future<void> setLastModified(DateTime time) async {
    _api.path(root, relative, 5, mtime: time.millisecondsSinceEpoch);
  }

  @override
  Future<FileStat> stat() async {
    // Native no-follow validation precedes this metadata-only Dart stat.
    await length();
    return FileStat.stat(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class SafeDirectory implements Directory {
  final String root;
  final String relative;
  SafeDirectory(this.root, this.relative);
  @override
  String get path => p.join(root, relative);
  @override
  Future<bool> exists() async =>
      SafeFile._api.path(root, relative, 6, missing: true) >= 0;
  List<FileSystemEntity> children() => SafeFile._api.list(root, relative);
  @override
  Future<Directory> create({bool recursive = false}) async {
    if (relative != '.') SafeFile._api.path(root, relative, 2);
    return this;
  }

  @override
  Future<Directory> delete({bool recursive = false}) async {
    if (recursive) throw UnsupportedError('Recursive deletion is forbidden');
    SafeFile._api.path(root, relative, 3);
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SafeHandle implements RandomAccessFile {
  int _id;
  @override
  final String path;
  _SafeHandle(this._id, this.path);
  @override
  Future<Uint8List> read(int bytes) async =>
      SafeFile._api.read(_id, bytes, path);
  @override
  Future<RandomAccessFile> setPosition(int position) async {
    SafeFile._api.io(_id, nullptr, 0, 2, position, path);
    return this;
  }

  @override
  Future<int> length() async => SafeFile._api.io(_id, nullptr, 0, 3, 0, path);
  @override
  Future<void> close() async {
    if (_id != 0) {
      SafeFile._api.close(_id);
      _id = 0;
    }
  }

  void write(List<int> bytes) => SafeFile._api.write(_id, bytes, path);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SafeConsumer implements StreamConsumer<List<int>> {
  final _SafeHandle file;
  _SafeConsumer(this.file);
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      file.write(bytes);
    }
  }

  @override
  Future<void> close() => file.close();
}

class _FileApi {
  static DynamicLibrary _load() {
    const override = String.fromEnvironment('MYSEND_NATIVE_LIBRARY');
    if (override.isNotEmpty) return DynamicLibrary.open(override);
    if (Platform.isWindows) {
      return DynamicLibrary.open(
          '${File(Platform.resolvedExecutable).parent.path}/mysend_transport.dll');
    }
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libmysend_transport.so');
    }
    // Development tests may use Dart TLS while retaining the safe file backend.
    return DynamicLibrary.open(
        'native/transport/target/release/${Platform.isMacOS ? 'libmysend_transport.dylib' : 'libmysend_transport.so'}');
  }

  final DynamicLibrary library = _load();
  late final _allocate = library.lookupFunction<Pointer<Uint8> Function(IntPtr),
      Pointer<Uint8> Function(int)>('mys_tls_alloc');
  Pointer<Uint8> alloc(int size) {
    final pointer = _allocate(size);
    if (pointer == nullptr) throw StateError('Native file allocation failed');
    return pointer;
  }

  late final free = library.lookupFunction<
      Void Function(Pointer<Uint8>, IntPtr),
      void Function(Pointer<Uint8>, int)>('mys_tls_free');
  late final _open = library.lookupFunction<
      Int64 Function(Pointer<Uint8>, Pointer<Uint8>, Int32),
      int Function(Pointer<Uint8>, Pointer<Uint8>, int)>('mys_fs_open');
  late final _path = library.lookupFunction<
      Int64 Function(
          Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Int32, Uint64),
      int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, int,
          int)>('mys_fs_path');
  late final _io = library.lookupFunction<
      Int64 Function(Uint64, Pointer<Uint8>, IntPtr, Int32, Uint64),
      int Function(int, Pointer<Uint8>, int, int, int)>('mys_fs_io');
  late final close =
      library.lookupFunction<Void Function(Uint64), void Function(int)>(
          'mys_fs_close');
  late final _error = library.lookupFunction<
      IntPtr Function(Pointer<Uint8>, IntPtr),
      int Function(Pointer<Uint8>, int)>('mys_fs_error');
  late final _list = library.lookupFunction<
      Int64 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, IntPtr),
      int Function(
          Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, int)>('mys_fs_list');
  List<FileSystemEntity> list(String root, String relative) {
    var capacity = 64 * 1024;
    while (true) {
      final allocated = capacity;
      final ptr = alloc(allocated);
      try {
        final length = check(
            text(
                root, (a) => text(relative, (b) => _list(a, b, ptr, capacity))),
            relative);
        if (length > capacity) {
          capacity = length;
          continue;
        }
        final bytes = ptr.asTypedList(length);
        final entries = <FileSystemEntity>[];
        var offset = 0;
        while (offset < length) {
          final type = bytes[offset++];
          var count = 0;
          while (bytes[offset] != 58) {
            count = count * 10 + bytes[offset++] - 48;
          }
          offset++;
          final name = utf8.decode(bytes.sublist(offset, offset + count));
          offset += count;
          final rel = relative == '.' ? name : '$relative/$name';
          entries
              .add(type == 68 ? SafeDirectory(root, rel) : SafeFile(root, rel));
        }
        return entries;
      } finally {
        free(ptr, allocated);
      }
    }
  }

  T text<T>(String value, T Function(Pointer<Uint8>) action) {
    if (value.contains('\u0000')) {
      throw FileSystemException('Invalid path', value);
    }
    final bytes = utf8.encode(value);
    final ptr = alloc(bytes.length + 1);
    try {
      ptr.asTypedList(bytes.length + 1)
        ..setAll(0, bytes)
        ..[bytes.length] = 0;
      return action(ptr);
    } finally {
      free(ptr, bytes.length + 1);
    }
  }

  int check(int result, String path,
      {bool missing = false, bool existing = false}) {
    if (result >= 0 ||
        (missing && result == -2) ||
        (existing && result == -3)) {
      return result;
    }
    final ptr = alloc(4096);
    try {
      final length = _error(ptr, 4096);
      throw FileSystemException(
          utf8.decode(ptr.asTypedList(length), allowMalformed: true), path);
    } finally {
      free(ptr, 4096);
    }
  }

  int open(String root, String relative, FileMode mode) => check(
      text(
          root,
          (a) => text(
              relative,
              (b) => _open(
                  a,
                  b,
                  mode == FileMode.read
                      ? 0
                      : mode == FileMode.append
                          ? 2
                          : 1))),
      relative);
  int path(String root, String rel, int op,
          {String target = '',
          int mtime = 0,
          bool missing = false,
          bool existing = false}) =>
      check(
          text(
              root,
              (a) => text(
                  rel, (b) => text(target, (c) => _path(a, b, c, op, mtime)))),
          rel,
          missing: missing,
          existing: existing);
  int io(int id, Pointer<Uint8> ptr, int len, int op, int offset,
          String path) =>
      check(_io(id, ptr, len, op, offset), path);
  Uint8List read(int id, int length, String path) {
    if (length == 0) return Uint8List(0);
    final ptr = alloc(length);
    try {
      final n = io(id, ptr, length, 0, 0, path);
      return Uint8List.fromList(ptr.asTypedList(n));
    } finally {
      free(ptr, length);
    }
  }

  void write(int id, List<int> bytes, String path) {
    if (bytes.isEmpty) return;
    final ptr = alloc(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      io(id, ptr, bytes.length, 1, 0, path);
    } finally {
      free(ptr, bytes.length);
    }
  }
}
