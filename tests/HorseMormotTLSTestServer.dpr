program HorseMormotTLSTestServer;

{$APPTYPE CONSOLE}

{
  Horse + mORMot2  —  TLS / mutual-TLS test server
  =================================================
  Destination: horse-provider-mormot/samples/tests/HorseMormotTLSTestServer.dpr

  Requires HORSE_PROVIDER_MORMOT in Project Options → Conditional defines.

  Listens on HTTPS port 9201 using the shared fixture certs (tests/certs/).
  Exercises the TLS support added to the mORMot provider (THorseMormotConfig
  SSL* fields → TNetTlsContext → THttpServerSocketGeneric.WaitStarted).

  TLS applies to the socket backends (mskThreadPool default, mskAsync). The
  http.sys backend (mskHttpApi) configures TLS at the OS level and rejects
  SSLEnabled at Listen time — so this test uses the default socket backend.
  Set HORSE_MORMOT_TEST_BACKEND=async to run it on mskAsync instead: the
  backend where hsoEnableTls only works through the constructor (B7).

  Two modes, selected by the first command-line argument:

    (no arg)   one-way TLS  — server presents server.crt.
    mtls       mutual TLS   — server requires a client cert signed by ca.crt.

  Routes:
    GET  /ping   → 200 "pong"
    POST /echo   → 200, echoes the request body

  Pair with HorseMormotTLSTestClient (same mode argument).
}

{$IFNDEF HORSE_PROVIDER_MORMOT}
  {$MESSAGE FATAL 'Set HORSE_PROVIDER_MORMOT in Project Options → Conditional defines'}
{$ENDIF}

// FORCE_OPENSSL is REQUIRED on Windows, and this guard exists because without
// it the failure is silent and looks like anything but its cause.
//
// NOTE these are // comments on purpose: the text below quotes compiler
// directives, and a closing brace inside a { } comment ends it early — which
// is exactly how the first version of this block broke the build.
//
// mORMot picks its TLS layer by whoever assigns NewNetTls first. On Windows
// mormot.net.sock.windows.inc does  NewNetTls := NewSChannelNetTls  during its
// own initialization, and mormot.lib.openssl11's initialization then declines
// to override it: its assignment is guarded by  $ifndef FORCE_OPENSSL  plus
// "if not Assigned(NewNetTls) then". So merely adding the OpenSSL unit to the
// uses clause changes nothing at all.
//
// That matters here because SChannel's SERVER side reads CertificateFile as a
// .pfx / PKCS#12 (see the field comments in mormot.net.sock.pas, and
// pfx := StringFromFile(Context.CertificateFile) in the windows .inc), while
// this test supplies PEM. The server then starts, logs "Listening on https",
// and has no usable credential: every handshake fails. curl reports
// "schannel: failed to receive handshake", and an HTTPS client whose
// ClientHello gets read as a malformed request line sees a bare 400 — which is
// what this suite reported before anyone looked at the transport.
//
// mORMot's own tools/mget/mget.dpr carries the same instruction: "on Windows,
// define FORCE_OPENSSL conditional in your project option".
//
// Runtime: libcrypto-3-x64.dll and libssl-3-x64.dll must sit beside the binary
// (build-tls-dcc.bat copies them).
{$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FORCE_OPENSSL)}
  {$MESSAGE FATAL 'Define FORCE_OPENSSL. Without it mORMot serves TLS through SChannel, whose server side expects a PFX rather than the PEM certs in certs/, and every handshake fails silently.'}
{$IFEND}

uses
  System.SysUtils,
  System.StrUtils,                 // IfThen (string)
  {$IFDEF MSWINDOWS}
  Winapi.Windows,                  // GetModuleHandle / GetModuleFileName
  mormot.lib.openssl11,            // must be USED as well as FORCE_OPENSSL defined
  {$ENDIF}
  Horse,
  Horse.Commons,
  Horse.Provider.Mormot.Config,    // THorseMormotConfig
  Horse.Provider.Mormot,
  HorseMormotTestBackend;          // HORSE_MORMOT_TEST_BACKEND (B7)

const
  TLS_PORT = 9201;

{$IFDEF MSWINDOWS}
// [TLS-OSSLVER-1] Which libcrypto file did this process load? The version
// text alone does not say whether it came from beside the binary or from
// PATH. mORMot keeps the loaded path private, so ask Windows for the module
// by the names mORMot tries. Never raises: '?' just means not found.
function LoadedLibCryptoPath: string;
const
  NAMES: array[0..3] of string = ('libcrypto-3-x64.dll', 'libcrypto-1_1-x64.dll',
    'libcrypto-3.dll', 'libcrypto-1_1.dll');
var
  LMod: HMODULE;
  LBuf: array[0..MAX_PATH] of Char;
  I:    Integer;
begin
  Result := '?';
  for I := Low(NAMES) to High(NAMES) do
  begin
    LMod := GetModuleHandle(PChar(NAMES[I]));
    if (LMod <> 0) and (GetModuleFileName(LMod, LBuf, Length(LBuf)) > 0) then
      Exit(LBuf);
  end;
end;
{$ENDIF}

function FindCertDir: string;
const
  CANDIDATES: array[0..3] of string = (
    'certs', '..\certs', 'tests\certs', '..\tests\certs');
var
  LBase, LCand: string;
  I: Integer;
begin
  LBase := ExtractFilePath(ParamStr(0));
  for I := Low(CANDIDATES) to High(CANDIDATES) do
  begin
    LCand := LBase + CANDIDATES[I] + PathDelim;
    if FileExists(LCand + 'server.crt') then
      Exit(LCand);
  end;
  for I := Low(CANDIDATES) to High(CANDIDATES) do
  begin
    LCand := CANDIDATES[I] + PathDelim;
    if FileExists(LCand + 'server.crt') then
      Exit(LCand);
  end;
  raise Exception.Create(
    'Could not locate certs\server.crt — copy tests\certs next to the binary.');
end;

procedure RegisterRoutes;
begin
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong').Status(THTTPStatus.OK);
    end);

  THorse.Post('/echo',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send(Req.Body).Status(THTTPStatus.OK);
    end);
end;

var
  Config:  THorseMormotConfig;
  CertDir: string;
  MTLS:    Boolean;
begin
  try
    MTLS    := SameText(ParamStr(1), 'mtls');
    CertDir := FindCertDir;

    Config                := THorseMormotConfig.Default;
    ApplyTestBackend(Config);        // raises on an unknown value
    Config.SSLEnabled     := True;
    Config.SSLCertFile    := CertDir + 'server.crt';
    Config.SSLPrivKeyFile := CertDir + 'server.key';

    if MTLS then
    begin
      Config.SSLCACertFile := CertDir + 'ca.crt';
      Config.SSLVerifyPeer := True;
    end;

    // run-tls-tests.bat pass 3. With mORMot2 2.4.16916+ the provider APPLIES
    // the suites (MORMOT-TLS13-SUITES-2): C1-C3 check that only ChaCha20 is
    // negotiated over TLS 1.3 and TLS 1.2 is untouched. With an older mORMot2
    // Listen refuses it instead (MORMOT-TLS13-SUITES-1).
    if SameText(ParamStr(1), 'suites13') then
      Config.SSLCipherSuitesTLS13 := 'TLS_CHACHA20_POLY1305_SHA256';
    // [MORMOT-TLS13-SUITES-2] pass 3 C4/C5: Listen must refuse, naming the
    // cause. 'SHA348' beside a valid suite is the realistic typo: OpenSSL keeps
    // the valid name and drops the typo without an error.
    if SameText(ParamStr(1), 'suites13typo') then
      Config.SSLCipherSuitesTLS13 := 'TLS_AES_256_GCM_SHA348:TLS_CHACHA20_POLY1305_SHA256';
    if SameText(ParamStr(1), 'suites13bad') then
      Config.SSLCipherSuitesTLS13 := 'TLS_NO_SUCH_SUITE';

    RegisterRoutes;

    Writeln(Format('[MormotTLSTest] certs: %s', [CertDir]));
    Writeln(Format('[MormotTLSTest] backend: %s', [BackendName(Config.ServerKind)]));
    Writeln(Format('[MormotTLSTest] mode : %s',
      [IfThen(MTLS, 'mutual TLS (client cert required)', 'one-way TLS')]));
    // Say WHICH TLS backend is live, and refuse to start on the one that
    // cannot work. Printing "Listening on https://..." regardless is how this
    // suite sat broken from 2026-06 until someone finally ran it: the server
    // reported itself healthy while SChannel had no usable credential, so every
    // failure surfaced at the client as a bare 400 and looked like a routing or
    // request problem rather than a dead transport.
    {$IFDEF MSWINDOWS}
    if not OpenSslIsAvailable then
      raise Exception.Create(
        'OpenSSL did not load, so mORMot would fall back to SChannel - whose '
        + 'server side expects a .pfx, not the PEM certs in certs/. Every '
        + 'handshake would fail while this process still looked healthy. Put '
        + 'libcrypto-3-x64.dll and libssl-3-x64.dll beside the binary '
        + '(build-tls-dcc.bat copies them).');
    Writeln(Format('[MormotTLSTest] TLS backend: OpenSSL %s from %s',
      [string(OpenSslVersionText), LoadedLibCryptoPath]));
    {$ENDIF}

    Writeln(Format('[MormotTLSTest] Listening on https://127.0.0.1:%d', [TLS_PORT]));
    Writeln('[MormotTLSTest] Run HorseMormotTLSTestClient'
      + IfThen(MTLS, ' mtls', '') + ' in a second terminal. Ctrl+C to stop.');

    THorseProviderMormot.ListenWithConfig(TLS_PORT, Config);
    Writeln('[MormotTLSTest] Server stopped.');
  except
    on E: Exception do
    begin
      Writeln('[MormotTLSTest] Fatal: ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
