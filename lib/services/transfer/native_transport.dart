import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// Native TLS carries LAN traffic; the Dart HTTP parser only sees loopback I/O.
/// Production Android/Windows builds require the bundled native library.
class NativeTransport {
  static final NativeTransport? instance = _load();
  static NativeTransport? _load() {
    const testLibrary = String.fromEnvironment('MYSEND_NATIVE_LIBRARY');
    if (testLibrary.isNotEmpty) {
      return NativeTransport(DynamicLibrary.open(testLibrary));
    }
    if (Platform.isAndroid) {
      return NativeTransport(DynamicLibrary.open('libmysend_transport.so'));
    }
    if (Platform.isWindows) {
      return NativeTransport(DynamicLibrary.open(
          '${File(Platform.resolvedExecutable).parent.path}/mysend_transport.dll'));
    }
    return null;
  }

  late final Pointer<Uint8> Function(int) _alloc;
  late final void Function(Pointer<Uint8>, int) _free;
  late final int Function(Pointer<Uint8>, Pointer<Uint8>, int, int) _server;
  late final int Function(Pointer<Uint8>, int, Pointer<Uint8>) _client;
  late final int Function(int) _port;
  late final void Function(int) _stop;
  late final void Function(int) _cancel;
  late final void Function(int, int) _cancelConnection;
  late final int Function(int, Pointer<Uint8>, int) _error;
  late final int Function(int, int, Pointer<Uint8>, int) _origin;

  NativeTransport(DynamicLibrary library) {
    _alloc = library.lookupFunction<Pointer<Uint8> Function(IntPtr),
        Pointer<Uint8> Function(int)>('mys_tls_alloc');
    _free = library.lookupFunction<Void Function(Pointer<Uint8>, IntPtr),
        void Function(Pointer<Uint8>, int)>('mys_tls_free');
    _server = library.lookupFunction<
        Uint64 Function(Pointer<Uint8>, Pointer<Uint8>, Uint16, Uint16),
        int Function(
            Pointer<Uint8>, Pointer<Uint8>, int, int)>('mys_tls_server_start');
    _client = library.lookupFunction<
        Uint64 Function(Pointer<Uint8>, Uint16, Pointer<Uint8>),
        int Function(
            Pointer<Uint8>, int, Pointer<Uint8>)>('mys_tls_client_start');
    _port = library.lookupFunction<Uint16 Function(Uint64), int Function(int)>(
        'mys_tls_port');
    _stop = library.lookupFunction<Void Function(Uint64), void Function(int)>(
        'mys_tls_stop');
    _cancel = library.lookupFunction<Void Function(Uint64), void Function(int)>(
        'mys_tls_cancel');
    _cancelConnection = library.lookupFunction<Void Function(Uint64, Uint16),
        void Function(int, int)>('mys_tls_cancel_connection');
    _error = library.lookupFunction<
        IntPtr Function(Uint64, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)>('mys_tls_error');
    _origin = library.lookupFunction<
        IntPtr Function(Uint64, Uint16, Pointer<Uint8>, IntPtr),
        int Function(int, int, Pointer<Uint8>, int)>('mys_tls_origin');
  }

  T _string<T>(String value, T Function(Pointer<Uint8>) use) {
    final bytes = utf8.encode(value);
    final pointer = _alloc(bytes.length + 1);
    if (pointer == nullptr) throw StateError('Native TLS allocation failed');
    try {
      pointer.asTypedList(bytes.length + 1)
        ..setAll(0, bytes)
        ..[bytes.length] = 0;
      return use(pointer);
    } finally {
      _free(pointer, bytes.length + 1);
    }
  }

  String _text(int Function(Pointer<Uint8>, int) read) {
    const capacity = 4096;
    final pointer = _alloc(capacity);
    if (pointer == nullptr) throw StateError('Native TLS allocation failed');
    try {
      final length = read(pointer, capacity);
      return utf8.decode(pointer.asTypedList(length), allowMalformed: true);
    } finally {
      _free(pointer, capacity);
    }
  }

  NativeTlsProxy server(
      String cert, String key, int innerPort, int preferredPort) {
    final id = _string(
        cert,
        (certPtr) => _string(key,
            (keyPtr) => _server(certPtr, keyPtr, innerPort, preferredPort)));
    return _handle(id);
  }

  NativeTlsProxy client(String host, int port, String fingerprint) {
    final id = _string(
        host,
        (hostPtr) => _string(fingerprint,
            (fingerprintPtr) => _client(hostPtr, port, fingerprintPtr)));
    return _handle(id);
  }

  NativeTlsProxy _handle(int id) {
    if (id == 0) {
      throw StateError(
          'Native TLS: ${_text((out, size) => _error(0, out, size))}');
    }
    return NativeTlsProxy._(this, id, _port(id));
  }
}

class NativeTlsProxy {
  final NativeTransport _api;
  final int _id;
  final int port;
  bool _closed = false;
  String _lastError = '';
  NativeTlsProxy._(this._api, this._id, this.port);
  String origin(int loopbackPort) =>
      _api._text((out, size) => _api._origin(_id, loopbackPort, out, size));
  String get error => _closed
      ? _lastError
      : _api._text((out, size) => _api._error(_id, out, size));
  void cancelConnection(int port) {
    if (!_closed) _api._cancelConnection(_id, port);
  }

  void cancelConnections() {
    if (!_closed) _api._cancel(_id);
  }

  void close() {
    if (!_closed) {
      _lastError = error;
      _closed = true;
      _api._stop(_id);
    }
  }
}
