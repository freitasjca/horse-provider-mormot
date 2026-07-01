unit Horse.Provider.Mormot.Config;

(*
  Horse mORMot Provider — Configuration record
  =============================================
  THorseMormotConfig is the single configuration point for the mORMot2
  transport.  It is a pure data record with no dependencies on Horse or
  mORMot so it can be referenced by both the abstract base and the
  provider without circular units.

  Dual-compilation: Delphi and FPC.
*)

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

const
  MORMOT_DEFAULT_THREAD_POOL       = 32;
  MORMOT_DEFAULT_MAX_BODY_BYTES    = Int64(4) * 1024 * 1024;  // 4 MB
  MORMOT_DEFAULT_MAX_HEADER_COUNT  = 100;
  MORMOT_DEFAULT_DRAIN_TIMEOUT_MS  = 5000;

type
  // Selects which mORMot2 HTTP server backend the provider hosts.
  //   mskThreadPool → THttpServer       (socket thread-pool; one thread per
  //                                       concurrent request — current default)
  //   mskAsync      → THttpAsyncServer  (non-blocking IOCP/epoll/kqueue event
  //                                       loop; scales past thread-per-request)
  //   mskHttpApi    → THttpApiServer    (Windows http.sys kernel-mode HTTP;
  //                                       port-sharing, URL ACLs — WINDOWS ONLY.
  //                                       Selecting it on a non-Windows build
  //                                       raises at Listen time.)
  // mskThreadPool/mskAsync descend from THttpServerSocketGeneric; mskHttpApi
  // descends straight from THttpServerGeneric (no socket base) and is built
  // differently (AddUrl + its own WaitStarted) — see the provider's InternalListen.
  TMormotServerKind = (mskThreadPool, mskAsync, mskHttpApi);

  THorseMormotConfig = record
    // Which mORMot2 HTTP server backend to host.
    // Default: mskThreadPool. Overridden project-wide by HORSE_MORMOT_ASYNC, or
    // (Windows only) HORSE_MORMOT_HTTPAPI.
    ServerKind:     TMormotServerKind;

    // mORMot THttpServer internal thread-pool size.
    // Each thread handles one concurrent request synchronously.
    // For mskAsync this is instead the number of async R/W event-loop threads
    // (NOT a per-request concurrency cap) — size it like CPU cores, not clients.
    // Default: 32
    ThreadPool:     Integer;

    // Maximum request body size (bytes).
    // Enforced by TMormotRequestBridge.Validate before the pipeline runs.
    // Default: 4 MB
    MaxBodyBytes:   Int64;

    // Maximum number of headers per request.
    // Excess headers are silently dropped (same as the CrossSocket provider).
    // Default: 100
    MaxHeaderCount: Integer;

    // Milliseconds to wait for in-flight requests to complete on Stop.
    // After this timeout shutdown proceeds regardless.
    // Default: 5000
    DrainTimeoutMs: Integer;

    // Value emitted in the HTTP Server: response header.
    // Empty string → 'unknown' to prevent library/version fingerprinting.
    // Default: ''
    ServerBanner:   string;

    // ── TLS / mTLS ────────────────────────────────────────────────────────────
    // Mirrors the SSL surface of the CrossSocket / ICS providers so the same
    // mental model (and the same cert files) apply across all three transports.
    // The provider builds a mORMot TNetTlsContext from these fields and passes it
    // to THttpServerSocketGeneric.WaitStarted(sec, @tls). TLS is supported on the
    // mskThreadPool and mskAsync (socket) backends; mskHttpApi (http.sys)
    // configures TLS at the OS level (netsh add sslcert), NOT through these fields.

    // Set True to listen on HTTPS. Requires SSLCertFile + SSLPrivKeyFile.
    // Default: False
    SSLEnabled:     Boolean;

    // Path to the server certificate (PEM). Maps to TNetTlsContext.CertificateFile.
    SSLCertFile:    string;

    // Path to the server private key (PEM). Maps to TNetTlsContext.PrivateKeyFile.
    SSLPrivKeyFile: string;

    // Passphrase for an encrypted private key. Maps to TNetTlsContext.PrivatePassword.
    SSLPassPhrase:  string;

    // CA bundle used to verify client certificates (mutual TLS). Optional —
    // required only when SSLVerifyPeer is True. Maps to TNetTlsContext.CACertificatesFile.
    SSLCACertFile:  string;

    // Require + verify a client certificate (mutual TLS). When True, sets
    // TNetTlsContext.ClientCertificateAuthentication and leaves
    // IgnoreCertificateErrors False so unauthenticated peers are rejected.
    // Default: False
    SSLVerifyPeer:  Boolean;

    // OpenSSL cipher list. Empty → mORMot/OpenSSL default. Maps to TNetTlsContext.CipherList.
    SSLCipherList:  string;

    class function Default: THorseMormotConfig; static;
  end;

implementation

class function THorseMormotConfig.Default: THorseMormotConfig;
begin
  // Provider-internal option defines (set project-wide, siblings of
  // HORSE_MORMOT_TRACE) pick the default backend: HORSE_MORMOT_HTTPAPI (Windows
  // only) → http.sys; else HORSE_MORMOT_ASYNC → async; else thread-pool. The
  // runtime field stays the primary switch — callers may override before
  // ListenWithConfig regardless of the define.
  {$IF DEFINED(HORSE_MORMOT_HTTPAPI) and DEFINED(MSWINDOWS)}
  Result.ServerKind     := mskHttpApi;     // Windows http.sys kernel-mode
  {$ELSEIF DEFINED(HORSE_MORMOT_ASYNC)}
  Result.ServerKind     := mskAsync;
  {$ELSE}
  Result.ServerKind     := mskThreadPool;
  {$IFEND}
  Result.ThreadPool     := MORMOT_DEFAULT_THREAD_POOL;
  Result.MaxBodyBytes   := MORMOT_DEFAULT_MAX_BODY_BYTES;
  Result.MaxHeaderCount := MORMOT_DEFAULT_MAX_HEADER_COUNT;
  Result.DrainTimeoutMs := MORMOT_DEFAULT_DRAIN_TIMEOUT_MS;
  Result.ServerBanner   := '';
  Result.SSLEnabled     := False;
  Result.SSLCertFile    := '';
  Result.SSLPrivKeyFile := '';
  Result.SSLPassPhrase  := '';
  Result.SSLCACertFile  := '';
  Result.SSLVerifyPeer  := False;
  Result.SSLCipherList  := '';
end;

end.
