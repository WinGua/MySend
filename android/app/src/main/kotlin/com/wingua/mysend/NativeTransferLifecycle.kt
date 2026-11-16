package com.wingua.mysend

/** Explicit task exit closes native TLS sockets, including blocked transfers. */
object NativeTransferLifecycle {
    init { System.loadLibrary("mysend_transport") }
    external fun stopAll()
}
