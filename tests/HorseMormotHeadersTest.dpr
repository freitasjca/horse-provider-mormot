program HorseMormotHeadersTest;

{$APPTYPE CONSOLE}

(*
  horse-provider-mormot - regression test for PR #27 (hsoHeadersUnfiltered)
  =========================================================================
  Authored 2026-10-27, NOT yet run - validate on Delphi / Win64 before trusting
  (same discipline as the other blind-authored tests in this repo).

  PR #27 adds hsoHeadersUnfiltered to the socket-backend options so mORMot2 stops
  filtering well-known request headers out of InHeaders. Built against the
  provider, this test proves two things on the wire:

    1. THE FIX - Accept-Encoding, User-Agent and Referer reach Req.Headers.
       Without PR #27 mORMot2 drops them, so the echoed values come back EMPTY.
       That is the CONTROL: build against an un-patched provider and checks 2-4
       must FAIL (the test has teeth only if the control fails).

    2. THE SIDE-EFFECT - a request carrying BOTH Content-Length and
       Transfer-Encoding is REJECTED (400), not answered 200. The provider's
       smuggling guard (TMormotRequestBridge.Validate) scans InHeaders, which
       only sees Content-Length / Transfer-Encoding once they are unfiltered, so
       PR #27 re-activates that guard.

  Self-contained: starts the mORMot provider in-process (default mskThreadPool)
  on a worker thread - THorse.Listen blocks on a console app (IsConsole = True),
  hence the thread - drives it with raw HTTP over a TCP socket (Indy
  TIdTCPClient, so malformed framing goes on the wire verbatim), then stops.
  Every request carries Connection: close so the read ends at the server close.
  Exit code = number of failed checks (0 = all passed), like the other tests.

  Backend note: hsoHeadersUnfiltered is applied identically to mskAsync (same
  LOpts set), so mskThreadPool here is representative for the header behaviour;
  async + TLS regression is covered by re-running samples/tests/build-tests-dcc.bat
  and tests/run-tls-tests.bat per backend.

  Build: copy tests/build-drain-dcc.bat to build-headers-dcc.bat and change the
  one line `set "NAME=HorseMormotDrainTest"` to `HorseMormotHeadersTest` (Indy's
  dcus are on the Win64 RTL lib path that script already adds). Then run the exe;
  it starts and stops its own server on port 9213.
*)

uses
  System.SysUtils,
  System.Classes,
  System.StrUtils,
  IdTCPClient,
  IdGlobal,
  Horse,
  Horse.Provider.Mormot;

const
  HOST     = '127.0.0.1';
  PORT     = 9213;
  CRLF     = #13#10;
  AE_MARK  = 'ae-sentinel-7f3a';
  UA_MARK  = 'ua-sentinel-7f3a';
  REF_MARK = 'ref-sentinel-7f3a';

var
  GPass:   Integer = 0;
  GFail:   Integer = 0;
  GServer: TThread;
  LResp:   string;

procedure Check(const AName: string; ACond: Boolean; const ADetail: string = '');
begin
  if ACond then
  begin
    Inc(GPass);
    Writeln('  [PASS] ' + AName);
  end
  else
  begin
    Inc(GFail);
    Writeln('  [FAIL] ' + AName + IfThen(ADetail <> '', '  -> ' + ADetail, ''));
  end;
end;

function FirstLine(const S: string): string;
var
  P: Integer;
begin
  P := Pos(#10, S);
  if P > 0 then
    Result := Trim(Copy(S, 1, P - 1))
  else
    Result := Trim(S);
end;

// ── Routes (plain procedures; Delphi assigns them to the callback type) ──────
procedure RoutePing(Req: THorseRequest; Res: THorseResponse);
begin
  Res.Send('pong');
end;

procedure RouteEcho(Req: THorseRequest; Res: THorseResponse);
begin
  // Echo the three well-known headers back as RESPONSE headers so the raw client
  // reads them from the header block without parsing a body.
  Res.AddHeader('X-AE',  Req.Headers['accept-encoding']);
  Res.AddHeader('X-UA',  Req.Headers['user-agent']);
  Res.AddHeader('X-REF', Req.Headers['referer']);
  Res.Send('ok');
end;

procedure RouteSink(Req: THorseRequest; Res: THorseResponse);
begin
  Res.Send('sink');
end;

// ── Server thread (Listen blocks on a console app) ───────────────────────────
type
  TServerThread = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TServerThread.Execute;
begin
  THorse.Listen(PORT);
end;

// ── Raw HTTP over a TCP socket ───────────────────────────────────────────────
function SendRaw(const ARequest: string): string;
var
  C:     TIdTCPClient;
  LLine: string;
begin
  Result := '';
  C := TIdTCPClient.Create(nil);
  try
    C.Host           := HOST;
    C.Port           := PORT;
    C.ConnectTimeout := 2000;
    C.ReadTimeout    := 3000;
    C.Connect;
    try
      C.IOHandler.Write(ARequest);
      try
        while C.Connected do
        begin
          LLine := C.IOHandler.ReadLn;
          if C.IOHandler.ReadLnTimedout then
            Break;
          Result := Result + LLine + #10;
        end;
      except
        // EIdConnClosedGracefully (server closed after Connection: close) or a
        // read timeout ends the response read - both are expected here.
        on E: Exception do ;
      end;
    finally
      if C.Connected then
        C.Disconnect;
    end;
  finally
    C.Free;
  end;
end;

function Ping: string;
begin
  Result := SendRaw('GET /ping HTTP/1.1' + CRLF + 'Host: ' + HOST + CRLF +
                    'Connection: close' + CRLF + CRLF);
end;

function WaitReady: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to 50 do
  begin
    try
      if Pos(' 200', Ping) > 0 then
        Exit(True);
    except
      // server not up yet
    end;
    Sleep(100);
  end;
end;

begin
  try
    THorse.Get('/ping',  RoutePing);
    THorse.Get('/echo',  RouteEcho);
    THorse.Post('/sink', RouteSink);

    GServer := TServerThread.Create(True);
    GServer.FreeOnTerminate := False;
    GServer.Start;
    try
      if not WaitReady then
      begin
        Writeln('FATAL: server did not start on ' + HOST + ':' + IntToStr(PORT));
        ExitCode := 2;
      end
      else
      begin
        Writeln('[headers-test] server up on ' + HOST + ':' + IntToStr(PORT));

        // 1 - control
        LResp := Ping;
        Check('control: GET /ping -> 200', Pos(' 200', LResp) > 0, FirstLine(LResp));

        // 2-4 - THE FIX: the well-known headers reach Req.Headers (echoed back)
        LResp := SendRaw(
          'GET /echo HTTP/1.1' + CRLF +
          'Host: ' + HOST + CRLF +
          'Accept-Encoding: gzip, ' + AE_MARK + CRLF +
          'User-Agent: ' + UA_MARK + CRLF +
          'Referer: http://' + REF_MARK + '/x' + CRLF +
          'Connection: close' + CRLF + CRLF);
        Check('Accept-Encoding reached Req.Headers (PR #27)', Pos(AE_MARK,  LResp) > 0, FirstLine(LResp));
        Check('User-Agent reached Req.Headers (PR #27)',      Pos(UA_MARK,  LResp) > 0, FirstLine(LResp));
        Check('Referer reached Req.Headers (PR #27)',         Pos(REF_MARK, LResp) > 0, FirstLine(LResp));

        // 5 - SIDE-EFFECT: Content-Length + Transfer-Encoding rejected, not 200
        LResp := SendRaw(
          'POST /sink HTTP/1.1' + CRLF +
          'Host: ' + HOST + CRLF +
          'Content-Length: 5' + CRLF +
          'Transfer-Encoding: chunked' + CRLF +
          'Connection: close' + CRLF + CRLF +
          '0' + CRLF + CRLF);
        Check('Content-Length + Transfer-Encoding rejected (400, not 200)',
          (Pos(' 200', LResp) = 0) and (Pos(' 400', LResp) > 0), FirstLine(LResp));

        // 6 - the server is still healthy after the malformed request
        Check('server healthy after the malformed request', Pos(' 200', Ping) > 0);
      end;

      THorse.StopListen;
      GServer.WaitFor;
    finally
      GServer.Free;
    end;

    Writeln('');
    Writeln(Format('[headers-test] %d passed, %d failed', [GPass, GFail]));
    if GFail > 0 then
      ExitCode := GFail;
  except
    on E: Exception do
    begin
      Writeln('[headers-test] EXCEPTION: ' + E.ClassName + ': ' + E.Message);
      ExitCode := 2;
    end;
  end;
end.
