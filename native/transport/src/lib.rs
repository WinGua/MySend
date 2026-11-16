//! Native TLS data plane. Only loopback HTTP is exposed to the Dart process;
//! LAN connections always use TLS 1.2/1.3 with a pinned peer certificate.
//! Design reference: LocalSend core HTTP certificate verifier and bounded I/O.
mod safe_fs;
use rustls::{
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    pki_types::{pem::PemObject, CertificateDer, PrivateKeyDer, ServerName, UnixTime},
    CertificateError, DigitallySignedStruct, Error, SignatureScheme,
};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    ffi::{c_char, CStr},
    net::{IpAddr, Ipv4Addr, SocketAddr},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::Duration,
};
use tokio::{
    net::{TcpListener, TcpStream},
    runtime::Runtime,
};
use tokio_rustls::{TlsAcceptor, TlsConnector};
use tokio_util::sync::CancellationToken;

const BUFFER: usize = 512 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static PROXIES: OnceLock<Mutex<HashMap<u64, Arc<Proxy>>>> = OnceLock::new();
static NEXT_ID: AtomicU64 = AtomicU64::new(1);
static LAST_ERROR: Mutex<String> = Mutex::new(String::new());
fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(
                std::thread::available_parallelism()
                    .map(|n| n.get())
                    .unwrap_or(2)
                    .clamp(2, 4),
            )
            .enable_all()
            .build()
            .expect("native I/O runtime")
    })
}
fn proxies() -> &'static Mutex<HashMap<u64, Arc<Proxy>>> {
    PROXIES.get_or_init(|| Mutex::new(HashMap::new()))
}
struct Proxy {
    port: u16,
    stop: CancellationToken,
    connections: Mutex<HashMap<u64, CancellationToken>>,
    origins: Mutex<HashMap<u16, String>>,
    origin_connections: Mutex<HashMap<u16, u64>>,
    error: Mutex<String>,
}
impl Proxy {
    fn fail(&self, error: impl ToString) {
        *self.error.lock().unwrap() = error.to_string();
    }
    fn cancel_connections(&self) {
        for (_, cancel) in self.connections.lock().unwrap().drain() {
            cancel.cancel();
        }
    }
}
#[derive(Debug)]
struct PinnedVerifier {
    fingerprint: String,
    provider: Arc<rustls::crypto::CryptoProvider>,
}
impl ServerCertVerifier for PinnedVerifier {
    fn verify_server_cert(
        &self,
        leaf: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        let actual = Sha256::digest(leaf.as_ref())
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        if actual != self.fingerprint {
            return Err(Error::InvalidCertificate(
                CertificateError::ApplicationVerificationFailure,
            ));
        }
        let (_, cert) = x509_parser::parse_x509_certificate(leaf.as_ref())
            .map_err(|_| Error::InvalidCertificate(CertificateError::BadEncoding))?;
        if !cert.validity().is_valid() {
            return Err(Error::InvalidCertificate(CertificateError::Expired));
        }
        cert.verify_signature(None)
            .map_err(|_| Error::InvalidCertificate(CertificateError::BadSignature))?;
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            signature,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            signature,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}
fn listener(port: u16, local_only: bool) -> Result<(TcpListener, Arc<Proxy>), String> {
    let address = if local_only {
        Ipv4Addr::LOCALHOST
    } else {
        Ipv4Addr::UNSPECIFIED
    };
    let listener = std::net::TcpListener::bind((address, port))
        .or_else(|e| {
            if port != 0 {
                std::net::TcpListener::bind((address, 0))
            } else {
                Err(e)
            }
        })
        .map_err(|e| e.to_string())?;
    listener.set_nonblocking(true).map_err(|e| e.to_string())?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let proxy = Arc::new(Proxy {
        port,
        stop: CancellationToken::new(),
        connections: Mutex::new(HashMap::new()),
        origins: Mutex::new(HashMap::new()),
        origin_connections: Mutex::new(HashMap::new()),
        error: Mutex::new(String::new()),
    });
    let _guard = runtime().enter();
    Ok((
        TcpListener::from_std(listener).map_err(|e| e.to_string())?,
        proxy,
    ))
}
fn insert(proxy: Arc<Proxy>) -> u64 {
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    proxies().lock().unwrap().insert(id, proxy);
    id
}
fn lookup(id: u64) -> Option<Arc<Proxy>> {
    proxies().lock().unwrap().get(&id).cloned()
}
fn connection(proxy: &Arc<Proxy>) -> (u64, CancellationToken) {
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let cancel = proxy.stop.child_token();
    proxy.connections.lock().unwrap().insert(id, cancel.clone());
    (id, cancel)
}
async fn connect(address: impl tokio::net::ToSocketAddrs) -> Result<TcpStream, String> {
    let stream = tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(address))
        .await
        .map_err(|_| "TCP connection timed out".to_owned())?
        .map_err(|e| e.to_string())?;
    stream.set_nodelay(true).map_err(|e| e.to_string())?;
    Ok(stream)
}
fn start_server(
    cert: &str,
    key: &str,
    inner_port: u16,
    preferred_port: u16,
) -> Result<u64, String> {
    if inner_port == 0 {
        return Err("missing loopback HTTP endpoint".into());
    }
    let certs: Vec<CertificateDer<'static>> = CertificateDer::pem_slice_iter(cert.as_bytes())
        .collect::<Result<_, _>>()
        .map_err(|e| e.to_string())?;
    let key = PrivateKeyDer::from_pem_slice(key.as_bytes()).map_err(|e| e.to_string())?;
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| e.to_string())?
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|e| e.to_string())?;
    let acceptor = TlsAcceptor::from(Arc::new(config));
    let (listener, proxy) = listener(preferred_port, false)?;
    let id = insert(proxy.clone());
    runtime().spawn(async move {
  loop {
   let accepted = tokio::select! { _ = proxy.stop.cancelled() => break, value = listener.accept() => value };
   let (socket, peer) = match accepted { Ok(value) => value, Err(e) => { proxy.fail(e); break; } };
   let _ = socket.set_nodelay(true);
   let (connection_id, cancel) = connection(&proxy); let proxy = proxy.clone(); let acceptor = acceptor.clone();
   runtime().spawn(async move {
    let mut origin_port = None;
    let work = async {
     let mut tls = tokio::time::timeout(CONNECT_TIMEOUT, acceptor.accept(socket)).await.map_err(|_| "TLS handshake timed out".to_owned())?.map_err(|e| e.to_string())?;
     let mut inner = connect(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), inner_port)).await?;
     let port = inner.local_addr().map_err(|e| e.to_string())?.port(); origin_port = Some(port);
     proxy.origins.lock().unwrap().insert(port, peer.ip().to_string());
     proxy.origin_connections.lock().unwrap().insert(port, connection_id);
     tokio::io::copy_bidirectional_with_sizes(&mut tls, &mut inner, BUFFER, BUFFER).await.map_err(|e| e.to_string())?;
     Ok::<(), String>(())
    };
    tokio::select! { _ = cancel.cancelled() => {}, result = work => if let Err(e) = result { proxy.fail(e); } }
    if let Some(port) = origin_port { proxy.origins.lock().unwrap().remove(&port); proxy.origin_connections.lock().unwrap().remove(&port); }
    proxy.connections.lock().unwrap().remove(&connection_id);
   });
  }
 });
    Ok(id)
}
fn start_client(host: String, port: u16, fingerprint: String) -> Result<u64, String> {
    if fingerprint.len() != 64
        || !fingerprint
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
    {
        return Err("invalid peer certificate fingerprint".into());
    }
    let name = ServerName::try_from(host.clone()).map_err(|e| e.to_string())?;
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let verifier = Arc::new(PinnedVerifier {
        fingerprint,
        provider: provider.clone(),
    });
    let config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| e.to_string())?
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_no_client_auth();
    let connector = TlsConnector::from(Arc::new(config));
    let (listener, proxy) = listener(0, true)?;
    let id = insert(proxy.clone());
    runtime().spawn(async move {
  loop {
   let accepted = tokio::select! { _ = proxy.stop.cancelled() => break, value = listener.accept() => value };
   let (mut inner, _) = match accepted { Ok(value) => value, Err(e) => { proxy.fail(e); break; } };
   let _ = inner.set_nodelay(true);
   let (connection_id, cancel) = connection(&proxy); let proxy = proxy.clone(); let connector = connector.clone(); let host = host.clone(); let name = name.clone();
   runtime().spawn(async move {
    let work = async {
     let socket = connect((host.as_str(), port)).await?;
     // Finish fingerprint and signature verification before forwarding any HTTP bytes.
     let mut tls = tokio::time::timeout(CONNECT_TIMEOUT, connector.connect(name, socket)).await.map_err(|_| "TLS handshake timed out".to_owned())?.map_err(|e| e.to_string())?;
     tokio::io::copy_bidirectional_with_sizes(&mut inner, &mut tls, BUFFER, BUFFER).await.map_err(|e| e.to_string())?;
     Ok::<(), String>(())
    };
    tokio::select! { _ = cancel.cancelled() => {}, result = work => if let Err(e) = result { proxy.fail(e); } }
    proxy.connections.lock().unwrap().remove(&connection_id);
   });
  }
 });
    Ok(id)
}
unsafe fn string(value: *const c_char) -> Result<String, String> {
    if value.is_null() {
        return Err("missing input".into());
    }
    CStr::from_ptr(value)
        .to_str()
        .map(String::from)
        .map_err(|e| e.to_string())
}
fn result(action: impl FnOnce() -> Result<u64, String> + std::panic::UnwindSafe) -> u64 {
    match std::panic::catch_unwind(action) {
        Ok(Ok(id)) => id,
        Ok(Err(e)) => {
            *LAST_ERROR.lock().unwrap() = e;
            0
        }
        Err(_) => {
            *LAST_ERROR.lock().unwrap() = "native TLS operation failed".into();
            0
        }
    }
}
/// # Safety
/// cert and key must be valid NUL-terminated UTF-8 PEM strings for this call.
#[no_mangle]
pub unsafe extern "C" fn mys_tls_server_start(
    cert: *const c_char,
    key: *const c_char,
    inner: u16,
    preferred: u16,
) -> u64 {
    result(|| start_server(&string(cert)?, &string(key)?, inner, preferred))
}
/// # Safety
/// host and fingerprint must be valid NUL-terminated UTF-8 strings for this call.
#[no_mangle]
pub unsafe extern "C" fn mys_tls_client_start(
    host: *const c_char,
    port: u16,
    fingerprint: *const c_char,
) -> u64 {
    result(|| start_client(string(host)?, port, string(fingerprint)?))
}
#[no_mangle]
pub extern "C" fn mys_tls_port(id: u64) -> u16 {
    lookup(id).map(|p| p.port).unwrap_or(0)
}
#[no_mangle]
pub extern "C" fn mys_tls_cancel(id: u64) {
    if let Some(proxy) = lookup(id) {
        proxy.cancel_connections();
    }
}
#[no_mangle]
pub extern "C" fn mys_tls_stop(id: u64) {
    if let Some(proxy) = proxies().lock().unwrap().remove(&id) {
        proxy.stop.cancel();
        proxy.cancel_connections();
    }
}
unsafe fn write_string(value: &str, out: *mut u8, size: usize) -> usize {
    if out.is_null() || size == 0 {
        return value.len();
    }
    let count = value.len().min(size - 1);
    std::ptr::copy_nonoverlapping(value.as_ptr(), out, count);
    *out.add(count) = 0;
    count
}
/// # Safety
/// out must be null or writable for size bytes; it must not alias native state.
#[no_mangle]
pub unsafe extern "C" fn mys_tls_error(id: u64, out: *mut u8, size: usize) -> usize {
    let text = lookup(id)
        .map(|p| p.error.lock().unwrap().clone())
        .unwrap_or_else(|| LAST_ERROR.lock().unwrap().clone());
    write_string(&text, out, size)
}
/// # Safety
/// out must be null or writable for size bytes; it must not alias native state.
#[no_mangle]
pub unsafe extern "C" fn mys_tls_origin(id: u64, port: u16, out: *mut u8, size: usize) -> usize {
    let text = lookup(id)
        .and_then(|p| p.origins.lock().unwrap().get(&port).cloned())
        .unwrap_or_default();
    write_string(&text, out, size)
}
/// # Safety
/// The returned allocation must only be freed with mys_tls_free using the same size.
#[no_mangle]
pub unsafe extern "C" fn mys_tls_alloc(size: usize) -> *mut u8 {
    if size == 0 {
        return std::ptr::null_mut();
    }
    std::alloc::alloc(std::alloc::Layout::from_size_align(size, 1).unwrap())
}
/// # Safety
/// ptr must be null or an allocation returned by mys_tls_alloc with this exact size.
#[no_mangle]
pub unsafe extern "C" fn mys_tls_free(ptr: *mut u8, size: usize) {
    if !ptr.is_null() && size != 0 {
        std::alloc::dealloc(ptr, std::alloc::Layout::from_size_align(size, 1).unwrap());
    }
}

#[no_mangle]
pub extern "C" fn mys_tls_cancel_connection(id: u64, port: u16) {
    if let Some(proxy) = lookup(id) {
        let connection = proxy.origin_connections.lock().unwrap().get(&port).copied();
        if let Some(connection) = connection {
            if let Some(cancel) = proxy.connections.lock().unwrap().get(&connection) {
                cancel.cancel();
            }
        }
    }
}
#[no_mangle]
pub extern "C" fn mys_tls_stop_all() {
    let entries: Vec<_> = proxies().lock().unwrap().drain().map(|(_, p)| p).collect();
    for proxy in entries {
        proxy.stop.cancel();
        proxy.cancel_connections();
    }
}
// Android invokes this only when its activity/task is explicitly destroyed.
#[no_mangle]
pub extern "system" fn Java_com_wingua_mysend_NativeTransferLifecycle_stopAll(
    _env: *mut std::ffi::c_void,
    _object: *mut std::ffi::c_void,
) {
    mys_tls_stop_all();
}
