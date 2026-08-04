unit Horse.Provider.Mormot;

(*
  Horse mORMot2 Provider  (hardened)
  ====================================
  High-performance HTTP transport for Horse using mORMot2's HTTP server stack.
  Three interchangeable backends, selected by THorseMormotConfig.ServerKind:
    mskThreadPool → THttpServer       (socket thread-pool — default)
    mskAsync      → THttpAsyncServer  (non-blocking IOCP/epoll/kqueue)
    mskHttpApi    → THttpApiServer    (Windows http.sys kernel-mode — WIN ONLY)
  All share the OnRequest handler, so the entire request/response bridge is
  identical across backends. mskThreadPool/mskAsync descend from
  THttpServerSocketGeneric; mskHttpApi descends from THttpServerGeneric.
  Uses IOCP on Windows, epoll on Linux — same kernel primitives as CrossSocket.

  ── Architecture ────────────────────────────────────────────────────────────
  mskThreadPool: THttpServer runs its own thread pool (THorseMormotConfig.
  ThreadPool, default 32). Each OnRequest callback runs synchronously on one of
  those threads — no separate THorseWorkerPool is needed.
  mskAsync: THttpAsyncServer runs a non-blocking event loop; ThreadPool then
  sizes the async R/W threads (not a per-request concurrency cap).
  mskHttpApi: THttpApiServer terminates HTTP in the Windows kernel (http.sys);
  InternalListen calls AddUrl to register http://+:<port>/ (needs admin rights
  or a one-time netsh urlacl) and uses its own WaitStarted. Windows-only —
  selecting it elsewhere raises at Listen. ThreadPool sizes the API threads.
  Backend is selectable at compile time via HORSE_MORMOT_ASYNC /
  HORSE_MORMOT_HTTPAPI (Windows) or at runtime via THorseMormotConfig.ServerKind.

  ── Security hardening (mirrors CrossSocket provider) ───────────────────────
  [SEC-29] Validate-before-pool.
           TMormotRequestBridge.Validate is called before acquiring a context
           from the pool.  Invalid requests are rejected with a structured JSON
           error; the pipeline is never entered.

  [SEC-30] Active-request tracking for graceful drain.
           FActiveRequests counter (TInterlocked) is incremented on every
           ExecutePipeline entry and decremented in the finally block.
           Stop() waits up to DrainTimeoutMs after mORMot threads exit.

  [SEC-31] Exceptions in the pipeline never leak internals to clients.
           Generic Exception → structured JSON 500; EHorseException → 4xx/5xx
           with the app-controlled message; EHorseCallbackInterrupted (BUG-2)
           → silently swallowed (normal pipeline-end signal).

  [SEC-32] Double-start guard.
           If Listen/ListenWithConfig is called while a server is running the
           existing server is cleanly stopped (with drain) before the new one
           starts.

  ── Fix log ─────────────────────────────────────────────────────────────────
  [BUG-2]  EHorseCallbackInterrupted caught explicitly — it is Horse's normal
           signal for pipeline completion; all providers swallow it silently.

  ── Design constraints ───────────────────────────────────────────────────────
  Requires the Horse fork patches:
    PATCH-REQ-1/2/3/8/9  (Horse.Request.pas)
    PATCH-RES-2/4/6      (Horse.Response.pas)
    PATCH-ABS-4          (Horse.Provider.Abstract.pas — MaxConnections class prop)
    Horse.Constants      (DEFAULT_PORT)
*)

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
  SyncObjs,
{$ELSE}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
{$ENDIF}
  Horse.Exception,
  Horse.Proc,
  Horse.Provider.Abstract,
  Horse.Provider.Mormot.Config,
  Horse.Provider.Mormot.Pool,
  Horse.Provider.Mormot.Request,
  Horse.Provider.Mormot.Response,
  Horse.Provider.Mormot.WebResponseAdapter,
  mormot.core.base,
  mormot.core.unicode,   // StringToUtf8 / Utf8ToString live here, not in mormot.core.base
  mormot.net.http,       // THttpServerRequestAbstract
  mormot.net.server,     // THttpServer + THttpServerSocketGeneric (shared base)
  mormot.net.async;      // THttpAsyncServer (mskAsync backend)

type
  THorseProviderMormot = class(THorseProviderAbstract)
  private
    // Common base of THttpServer, THttpAsyncServer AND THttpApiServer (http.sys)
    // — holds whichever backend AConfig.ServerKind selects. OnRequest, Shutdown
    // and the request-handler signature live on this base. (WaitStarted does NOT
    // — its signature differs per family, so it is called per-branch on the
    // concrete type inside InternalListen.)
    class var FServer:         THttpServerGeneric;
    class var FPort:           Integer;
    // Bind host set by the Listen overload family (upstream 2026-07 sync).
    // '' or '0.0.0.0' = all interfaces. On the socket backends a specific
    // host becomes mORMot's 'host:port' aPort syntax; the http.sys backend
    // ignores it (binds all hostnames via the '+' wildcard prefix).
    class var FHost:           string;
    class var FConfig:         THorseMormotConfig;
    class var FStopEvent:      TEvent;
    class var FRunning:        Boolean;
    class var FHandler:        TObject;
    class var FActiveRequests: Integer;
    class var FDrainEvent:     TEvent;

    class function  GetPort: Integer; static;
    class procedure SetPort(const AValue: Integer); static;
    // mORMot aPort string for the socket backends: '8080' or 'host:8080'.
    class function  BindAddr(const APort: Integer): RawUtf8; static;

    // [SEC-31] Minimal structured error response without entering the pipeline
    class function SendError(
      const ACtxt:    THttpServerRequestAbstract;
            AStatus:  Integer;
      const AMessage: string
    ): cardinal; static;

    // Main request handler — called by TMormotHandler.Process on each request
    class function ExecutePipeline(
      Ctxt: THttpServerRequestAbstract
    ): cardinal; static;

    class procedure InternalListen(
      const APort:   Integer;
      const AConfig: THorseMormotConfig
    );

  public
    // ── Overrides matching THorseProviderAbstract ──────────────────────────
    class procedure StopListen; override;
    class procedure Listen; overload; override;

    // ── Non-virtual convenience overloads ─────────────────────────────────

    // Listen overload family — signatures mirror the Console provider.
    // Required since the 2026-07 upstream sync: Horse.Instance
    // (THorseInstance.Listen) calls the 4-argument form directly.
    class procedure Listen(const APort: Integer; const AHost: string = '0.0.0.0'; const ACallbackListen: TProc = nil; const ACallbackStopListen: TProc = nil); reintroduce; overload; static;
    class procedure Listen(const APort: Integer; const ACallbackListen: TProc; const ACallbackStopListen: TProc = nil); reintroduce; overload; static;
    class procedure Listen(const AHost: string; const ACallbackListen: TProc = nil; const ACallbackStopListen: TProc = nil); reintroduce; overload; static;
    class procedure Listen(const ACallbackListen: TProc; const ACallbackStopListen: TProc = nil); reintroduce; overload; static;
    // `reintroduce` because the abstract base declares
    //   class procedure ListenWithConfig(APort: Integer;
    //     const AConfig: THorseCrossSocketConfig); virtual;
    // taking a CrossSocket-specific record type. The mORMot variant takes
    // THorseMormotConfig — different signature, intentional hide.
    class procedure ListenWithConfig(
      const APort:   Integer;
      const AConfig: THorseMormotConfig
    ); reintroduce;

    // Direct stop — called by StopListen; also available to external code.
    class procedure Stop;

    class property Port:   Integer            read GetPort   write SetPort;
    class property Config: THorseMormotConfig read FConfig;
  end;

implementation

uses
  Horse,
  Horse.Commons,
  mormot.net.sock,           // RemoteIPLocalHostAsVoidInServers
  // ── NB: Horse.Constants MUST come after mormot.net.sock — both declare
  // DEFAULT_PORT (Horse: Integer 9000; mORMot: array[boolean] of RawUtf8
  // '80'/'443'), and Pascal resolves identifiers from the LAST unit in the
  // uses clause first. Listing Horse.Constants last makes the unqualified
  // DEFAULT_PORT in Listen() resolve to Horse's Integer 9000 as intended.
  Horse.Constants,
  Horse.Exception.Interrupted;

// ── Internal handler object ────────────────────────────────────────────────────
// mORMot's OnRequest is a method-of-object; we bridge to the class method.
type
  TMormotHandler = class
  public
    function Process(Ctxt: THttpServerRequestAbstract): cardinal;
  end;

function TMormotHandler.Process(Ctxt: THttpServerRequestAbstract): cardinal;
begin
  Result := THorseProviderMormot.ExecutePipeline(Ctxt);
end;

{ THorseProviderMormot }

// ── Port accessors ────────────────────────────────────────────────────────────
class function THorseProviderMormot.GetPort: Integer;
begin
  Result := FPort;
end;

class procedure THorseProviderMormot.SetPort(const AValue: Integer);
begin
  FPort := AValue;
end;

// ── Listen (no-arg override) ──────────────────────────────────────────────────
class procedure THorseProviderMormot.Listen;
var
  LPort: Integer;
begin
  LPort := FPort;
  if LPort <= 0 then
    LPort := DEFAULT_PORT;
  InternalListen(LPort, THorseMormotConfig.Default);
end;

// ── Listen overload family ────────────────────────────────────────────────────
// Master overload: stores host + lifecycle callbacks, then starts with the
// default config. DoOnListen (fired inside InternalListen) invokes the
// just-set ACallbackListen; DoOnStopListen fires from StopListen.
class procedure THorseProviderMormot.Listen(const APort: Integer; const AHost: string; const ACallbackListen, ACallbackStopListen: TProc);
begin
  FHost := AHost;
  SetOnListen(ACallbackListen);
  SetOnStopListen(ACallbackStopListen);
  InternalListen(APort, THorseMormotConfig.Default);
end;

class procedure THorseProviderMormot.Listen(const APort: Integer; const ACallbackListen, ACallbackStopListen: TProc);
begin
  Listen(APort, FHost, ACallbackListen, ACallbackStopListen);
end;

class procedure THorseProviderMormot.Listen(const AHost: string; const ACallbackListen, ACallbackStopListen: TProc);
var
  LPort: Integer;
begin
  LPort := FPort;
  if LPort <= 0 then
    LPort := DEFAULT_PORT;
  Listen(LPort, AHost, ACallbackListen, ACallbackStopListen);
end;

class procedure THorseProviderMormot.Listen(const ACallbackListen, ACallbackStopListen: TProc);
begin
  Listen(FHost, ACallbackListen, ACallbackStopListen);
end;

// ── BindAddr — mORMot aPort string, optionally host-qualified ─────────────────
// mORMot's aPort accepts '8080' (all interfaces) or 'host:8080' (specific bind)
// — see mormot.net.server.pas 'ip:port' convention.
class function THorseProviderMormot.BindAddr(const APort: Integer): RawUtf8;
begin
  if (FHost = '') or (FHost = '0.0.0.0') then
    Result := StringToUtf8(IntToStr(APort))
  else
    Result := StringToUtf8(FHost + ':' + IntToStr(APort));
end;

// ── ListenWithConfig ──────────────────────────────────────────────────────────
class procedure THorseProviderMormot.ListenWithConfig(
  const APort:   Integer;
  const AConfig: THorseMormotConfig
);
begin
  InternalListen(APort, AConfig);
end;

// ── InternalListen ────────────────────────────────────────────────────────────
class procedure THorseProviderMormot.InternalListen(
  const APort:   Integer;
  const AConfig: THorseMormotConfig
);
var
  LHandler:    TMormotHandler;
  LSockServer: THttpServerSocketGeneric;
  {$IFDEF MSWINDOWS}
  LApiServer:  THttpApiServer;
  {$ENDIF}
  LTls:    TNetTlsContext;
  LUseTls: Boolean;
begin
  // [SEC-32] Stop any running server before starting a new one
  if Assigned(FServer) then
    Stop;

  // TLS is unsupported on the http.sys backend (certs bind at the OS level via
  // netsh add sslcert) — reject early, before any allocation.
  if AConfig.SSLEnabled and (AConfig.ServerKind = mskHttpApi) then
    raise Exception.Create(
      'THorseMormotConfig.SSLEnabled is not supported on the mskHttpApi (http.sys) ' +
      'backend — bind the certificate at the OS level with: ' +
      'netsh http add sslcert ipport=0.0.0.0:<port> certhash=<thumbprint> appid={<guid>}');

  FConfig := AConfig;
  FPort   := APort;

  if not Assigned(FDrainEvent) then
    FDrainEvent := TEvent.Create(nil, True, True, '');  // manual-reset, signalled

  LHandler := TMormotHandler.Create;
  FHandler := LHandler;

  // Select the backend. THttpServer / THttpAsyncServer share the
  // THttpServerSocketGeneric.Create(port, onStart, onStop, name, threadPool)
  // signature; THttpApiServer (http.sys) has a different constructor + AddUrl
  // and is Windows-only, so it lives in its own {$IFDEF MSWINDOWS} branch.
  case AConfig.ServerKind of
    mskAsync:
      begin
        LSockServer := THttpAsyncServer.Create(
          BindAddr(APort), nil, nil, '', AConfig.ThreadPool);
        FServer := LSockServer;
      end;

    mskHttpApi:
      begin
        {$IFDEF MSWINDOWS}
        // http.sys kernel-mode server. AddUrl registers the listening prefix:
        //   '' root + '+' strong wildcard ⇒ http://+:<port>/ (all host names).
        // aRegisterUri=True asks http.sys to add the reservation, which needs
        // Administrator rights OR a prior one-time, per-port:
        //   netsh http add urlacl url=http://+:<port>/ user=<account>
        // AddUrl returns an error code (0 = NO_ERROR) — it does NOT raise — so a
        // non-admin / missing-urlacl failure would otherwise bind nothing and
        // silently drop every request. Fail loudly with the fix in the message.
        LApiServer := THttpApiServer.Create(
          '', nil, nil, '', [], nil, AConfig.ThreadPool);
        if LApiServer.AddUrl('', StringToUtf8(IntToStr(APort)), False, '+', True) <> 0 then
        begin
          FreeAndNil(LApiServer);
          FreeAndNil(FHandler);
          raise Exception.CreateFmt(
            'http.sys AddUrl failed for http://+:%d/ — run as Administrator, or ' +
            'pre-authorize once with: netsh http add urlacl url=http://+:%d/ user=<account>',
            [APort, APort]);
        end;
        FServer := LApiServer;
        {$ELSE}
        FreeAndNil(FHandler);
        raise Exception.Create(
          'THorseMormotConfig.ServerKind = mskHttpApi (http.sys) is Windows-only');
        {$ENDIF}
      end;

  else // mskThreadPool (default)
    begin
      LSockServer := THttpServer.Create(
        BindAddr(APort), nil, nil, '', AConfig.ThreadPool);
      FServer := LSockServer;
    end;
  end;

  FServer.OnRequest := LHandler.Process;

  // ── TLS [SEC-TLS-1] ─────────────────────────────────────────────────────────
  // Build a mORMot TNetTlsContext from the SSL* config fields and hand it to the
  // socket server's WaitStarted overload, which loads the cert/key into the
  // OpenSSL context at bind time. TLS applies to the socket backends only; the
  // http.sys backend binds its certificate at the OS level (netsh add sslcert),
  // so SSLEnabled + mskHttpApi is rejected early at the top of InternalListen.
  LUseTls := AConfig.SSLEnabled and (AConfig.ServerKind <> mskHttpApi);
  if LUseTls then
  begin
    // Server=True ⇒ require CertificateFile/PrivateKeyFile; without mutual auth
    // InitNetTlsContext leaves IgnoreCertificateErrors True (server presents its
    // cert, does not demand one from the client) — that is one-way HTTPS.
    InitNetTlsContext(LTls, {Server=}True,
      AConfig.SSLCertFile, AConfig.SSLPrivKeyFile,
      StringToUtf8(AConfig.SSLPassPhrase), AConfig.SSLCACertFile);
    if AConfig.SSLVerifyPeer then
    begin
      // Mutual TLS: demand a client cert and verify it against CACertificatesFile.
      LTls.ClientCertificateAuthentication := True;
      LTls.IgnoreCertificateErrors         := False;
    end;
    if AConfig.SSLCipherList <> '' then
      LTls.CipherList := StringToUtf8(AConfig.SSLCipherList);
  end;

  // WaitStarted is NOT on THttpServerGeneric and its signature differs per
  // family — call it on the concrete type. (http.sys: WaitStarted: boolean.)
  if AConfig.ServerKind = mskHttpApi then
    {$IFDEF MSWINDOWS}
    THttpApiServer(FServer).WaitStarted(10)
    {$ENDIF}
  else if LUseTls then
    THttpServerSocketGeneric(FServer).WaitStarted(10, @LTls)  // bind with TLS
  else
    THttpServerSocketGeneric(FServer).WaitStarted(10);   // wait up to 10 s to bind

  DoOnListen;

  // Block main thread in console apps.  Non-console shapes (VCL, service, LCL)
  // have their own message loops — IsConsole = False, so we return immediately.
  if IsConsole then
  begin
    FRunning := True;
    if not Assigned(FStopEvent) then
      FStopEvent := TEvent.Create(nil, True, False, '');   // manual-reset, unsignalled
    while FRunning do
      FStopEvent.WaitFor(INFINITE);
    FreeAndNil(FStopEvent);
  end;
end;

// ── StopListen (base override) ────────────────────────────────────────────────
class procedure THorseProviderMormot.StopListen;
begin
  Stop;
  DoOnStopListen;
end;

// ── Stop ──────────────────────────────────────────────────────────────────────
class procedure THorseProviderMormot.Stop;
begin
  FRunning := False;

  // Free the mORMot server — this terminates its internal thread pool.
  if Assigned(FServer) then
  begin
    FreeAndNil(FServer);
    FreeAndNil(FHandler);
  end;

  // [SEC-30] Wait for any in-flight ExecutePipeline calls to complete.
  // After FServer.Free, mORMot threads have stopped; FActiveRequests should
  // already be 0, but we honour the drain timeout for safety.
  {$IF DEFINED(FPC)}
  if InterlockedCompareExchange(FActiveRequests, 0, 0) > 0 then
  {$ELSE}
  if TInterlocked.CompareExchange(FActiveRequests, 0, 0) > 0 then
  {$ENDIF}
    if Assigned(FDrainEvent) then
      FDrainEvent.WaitFor(FConfig.DrainTimeoutMs);

  FreeAndNil(FDrainEvent);

  // Unblock the main thread (InternalListen is waiting on FStopEvent)
  if Assigned(FStopEvent) then
    FStopEvent.SetEvent;
end;

// ── ExecutePipeline ───────────────────────────────────────────────────────────
//
// Diagnostic tracing
// ------------------
// Enable HORSE_MORMOT_TRACE in Project Options → Conditional defines to print
// a checkpoint log line for every phase of the request lifecycle. Output goes
// to stdout so it interleaves with the console server's own writeln output.
// Each line is prefixed with the request method + URL + thread ID so concurrent
// requests can be told apart. Use this to isolate where a hung request dies:
//
//   ENTER   → OnRequest fired (mORMot dispatched to us)
//   VALOK   → Validate returned rvOK (pre-pool checks passed)
//   POOLED  → Acquired a THorseContext from the pool
//   POPED   → Request bridge populated headers/params/body
//   ADAPTER → RawWebResponse adapter installed
//   ROUTE   → THorse.Execute returned without raising
//   FLUSHED → Response bridge ran; status code captured
//   DONE    → Returning to mORMot with status N
//
// If a test hangs and you see ROUTE but no FLUSHED, the bug is in Flush.
// If you see ENTER but no VALOK, validation rejected the request.
// If you see no ENTER at all, mORMot never called us (problem inside mORMot).
class function THorseProviderMormot.ExecutePipeline(
  Ctxt: THttpServerRequestAbstract
): cardinal;
{$IFDEF HORSE_MORMOT_TRACE}
var
  LTag: string;
  procedure Trace(const APhase: string);
  begin
    System.Writeln(Format('[trace %s tid=%d] %s', [LTag,
      TThread.CurrentThread.ThreadID, APhase]));
    System.Flush(System.Output);   // unbuffered so a hang doesn't lose the line
  end;
{$ENDIF}
var
  ValResult:    TRequestValidationResult;
  RejectReason: string;
  Ctx:          THorseContext;
  Banner:       string;
begin
  // Initialise Result so the `finally` block (and the HORSE_MORMOT_TRACE
  // diagnostic at DONE) always reads a defined value, even if an exception
  // is raised before SendError / Flush assigns Result explicitly.
  // 500 = "Internal Server Error" — appropriate fallback if our pipeline
  // somehow lets an unhandled exception escape the inner try/except below.
  Result := 500;

  {$IFDEF HORSE_MORMOT_TRACE}
  LTag := Utf8ToString(Ctxt.Method) + ' ' + Utf8ToString(Ctxt.Url);
  Trace('ENTER');
  {$ENDIF}

  // [SEC-30] Count this request for graceful-drain accounting
  {$IF DEFINED(FPC)}
  if InterlockedIncrement(FActiveRequests) = 1 then
  {$ELSE}
  if TInterlocked.Increment(FActiveRequests) = 1 then
  {$ENDIF}
    if Assigned(FDrainEvent) then
      FDrainEvent.ResetEvent;

  try

    // ── [SEC-29] Validate BEFORE touching the pool ──────────────────────────
    ValResult := TMormotRequestBridge.Validate(
      Ctxt, RejectReason, FConfig.MaxBodyBytes);

    if ValResult <> rvOK then
    begin
      {$IFDEF HORSE_MORMOT_TRACE}
      Trace(Format('REJECT %d (%s)', [Ord(ValResult), RejectReason]));
      {$ENDIF}
      case ValResult of
        rvMethodNotAllowed: Result := SendError(Ctxt, 405, 'Method Not Allowed');
        rvPayloadTooLarge:  Result := SendError(Ctxt, 413, 'Payload Too Large');
        rvBadRequest:       Result := SendError(Ctxt, 400, 'Bad Request');
      else
        Result := SendError(Ctxt, 400, 'Bad Request');
      end;
      Exit;
    end;
    {$IFDEF HORSE_MORMOT_TRACE} Trace('VALOK'); {$ENDIF}

    Banner := FConfig.ServerBanner;

    // ── Pool acquire ─────────────────────────────────────────────────────────
    Ctx := THorseContextPool.Acquire;
    {$IFDEF HORSE_MORMOT_TRACE} Trace('POOLED'); {$ENDIF}
    try

      TMormotRequestBridge.Populate(Ctxt, Ctx.Request, FConfig.MaxHeaderCount);
      {$IFDEF HORSE_MORMOT_TRACE} Trace('POPED'); {$ENDIF}

      // [PATCH-RES-6] RawWebResponse adapter so middleware calling
      // Res.RawWebResponse.SetCustomHeader (e.g. Horse.CORS) gets a non-nil
      // TWebResponse backed by this mORMot context.
      Ctx.Response.SetCSRawWebResponse(TMormotWebResponse.Create(Ctxt));
      {$IFDEF HORSE_MORMOT_TRACE} Trace('ADAPTER'); {$ENDIF}

      // ── Horse pipeline ────────────────────────────────────────────────────
      try
        THorse.Execute(Ctx.Request, Ctx.Response);
        {$IFDEF HORSE_MORMOT_TRACE} Trace('ROUTE'); {$ENDIF}
      except
        // [BUG-2] EHorseCallbackInterrupted is Horse's normal pipeline-end
        // signal — response is already populated; swallow silently.
        on EHorseCallbackInterrupted do
          {$IFDEF HORSE_MORMOT_TRACE} Trace('ROUTE-INTERRUPTED') {$ENDIF};

        on E: EHorseException do
        begin
          {$IFDEF HORSE_MORMOT_TRACE}
          Trace(Format('ROUTE-EHORSE %s: %s', [E.ClassName, E.Message]));
          {$ENDIF}
          Ctx.Response.Status(E.Status);
          Ctx.Response.Send(Format('{"error":"%s"}', [E.Message]));
          Ctx.Response.ContentType('application/json; charset=utf-8');
        end;

        on E: Exception do
        begin
          // [SEC-31] Log internally; NEVER leak stack or detail to client
          System.WriteLn(ErrOutput,
            Format('[HorseMormot] Pipeline exception %s: %s',
              [E.ClassName, E.Message]));
          {$IFDEF HORSE_MORMOT_TRACE}
          Trace(Format('ROUTE-EXCEPTION %s: %s', [E.ClassName, E.Message]));
          {$ENDIF}
          Ctx.Response.Status(THTTPStatus.InternalServerError);
          Ctx.Response.Send('{"error":"Internal Server Error"}');
          Ctx.Response.ContentType('application/json; charset=utf-8');
        end;
      end;

      Result := TMormotResponseBridge.Flush(Ctx.Response, Ctxt, Banner);
      {$IFDEF HORSE_MORMOT_TRACE}
      Trace(Format('FLUSHED status=%d body-bytes=%d', [Result,
        Length(Ctxt.OutContent)]));
      {$ENDIF}

    finally
      THorseContextPool.Release(Ctx);
    end;

  finally
    // [SEC-30] Always decrement — even on validation reject or exception
    {$IF DEFINED(FPC)}
    if InterlockedDecrement(FActiveRequests) = 0 then
    {$ELSE}
    if TInterlocked.Decrement(FActiveRequests) = 0 then
    {$ENDIF}
      if Assigned(FDrainEvent) then
        FDrainEvent.SetEvent;
    {$IFDEF HORSE_MORMOT_TRACE} Trace(Format('DONE status=%d', [Result])); {$ENDIF}
  end;
end;

// ── [SEC-31] SendError ────────────────────────────────────────────────────────
class function THorseProviderMormot.SendError(
  const ACtxt:    THttpServerRequestAbstract;
        AStatus:  Integer;
  const AMessage: string
): cardinal;
var
  Banner:   string;
  LHeaders: string;
begin
  if FConfig.ServerBanner <> '' then
    Banner := FConfig.ServerBanner
  else
    Banner := 'unknown';

  // Accumulate into a string first; convert once to avoid implicit UTF-16→UTF-8
  // coercions on the RawUtf8 field that corrupt non-ASCII banner values.
  LHeaders :=
    'X-Content-Type-Options: nosniff'#13#10 +
    'X-Frame-Options: DENY'#13#10 +
    'Cache-Control: no-store'#13#10 +
    'Server: ' + Banner + #13#10;

  ACtxt.OutContentType   := 'application/json; charset=utf-8';
  ACtxt.OutCustomHeaders := StringToUtf8(LHeaders);
  ACtxt.OutContent       := StringToUtf8(
    Format('{"error":"%s"}',
      [StringReplace(AMessage, '"', '\"', [rfReplaceAll])])
  );
  Result := cardinal(AStatus);
end;

initialization
  // mORMot2 defaults RemoteIPLocalHostAsVoidInServers to True, which reports
  // loopback connections (127.0.0.1) with an empty RemoteIP to keep server
  // logs quiet. Horse's cross-provider contract is that Req.RawWebRequest
  // .RemoteAddr returns the literal peer IP — matching what Indy and
  // CrossSocket return for loopback. Flip the mORMot flag so middleware that
  // inspects RemoteAddr (rate limiters, audit loggers, etc.) sees the same
  // value on every transport.
  RemoteIPLocalHostAsVoidInServers := False;

end.
