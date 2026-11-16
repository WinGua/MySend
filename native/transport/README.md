# Native TLS transport

The existing MySend HTTP protocol runs through bounded native TLS tunnels. LAN listeners use rustls TLS 1.2/1.3; unencrypted HTTP listeners bind only to loopback. A peer's SHA-256 certificate fingerprint, validity and handshake signatures are checked before its HTTP bytes are forwarded. Tokens, private-key pairing challenges and dual-device sync leases are enforced by the protocol server. Mapping file access uses no-follow directory handles; publication atomically refuses an existing destination.

The TLS adapter uses certificate pinning and bounded streaming. Design reference: [LocalSend (fixed revision)](https://github.com/localsend/localsend/tree/2e7ef1972b0b4e210608ec77ef5fad334f798f7e) (Apache-2.0, Copyright 2022–2026 Tien Do Nam). This adapter is independently implemented; no LocalSend source files are bundled.

Rust is pinned in the repository toolchain file; Cargo.lock pins dependencies. Android requires NDK 26.1.10909125 and the three Rust Android targets. `python3 tool/build_native.py android` builds packaged JNI libraries (also called by Gradle). Windows CMake builds and installs `mysend_transport.dll`. Production builds require the native library; a missing library is reported as a startup error.

For host verification: `cargo build --manifest-path native/transport/Cargo.toml --release --locked`, then run Flutter tests with `--dart-define=MYSEND_NATIVE_LIBRARY=<absolute .so/.dylib path>`. The same tests can run without that define to verify the Dart TLS compatibility path. `tool/native_transport_benchmark.dart` compares both TLS implementations using SHA-256 verified payloads; localhost results do not predict phone Wi-Fi performance.
