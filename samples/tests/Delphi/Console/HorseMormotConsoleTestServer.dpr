program HorseMormotConsoleTestServer;

{
  Horse + mORMot2 Provider — Integration Test Server (Delphi · Console shape)
  ============================================================================

  Project type: Console Application.

  No special compiler defines are required. Include Horse.Provider.Mormot
  directly in the uses clause; once Horse.pas is patched with
  HORSE_PROVIDER_MORMOT routing the alternative define will also work:

    HORSE_PROVIDER_MORMOT   (future — when Horse.pas routes this define)

  mORMot's THttpServer uses IOCP (Windows) / epoll (Linux) and manages its
  own thread pool (default 32 threads). When IsConsole = True, InternalListen
  blocks the main thread on a TEvent until Stop signals it.
  SetConsoleCtrlHandler unblocks it on Ctrl-C / Ctrl-Break / SCM stop.

  Routes: see ..\..\Common\Horse.Mormot.TestRoutes.pas — same 32 surfaces
  the shared HorseCSTestClient.dpr exercises.

  Run sequence:
    1. Start this server.
    2. Run HorseCSTestClient.exe (from horse-provider-crosssocket/samples/tests/).
    3. Expect the same pass/fail counts as the CrossSocket console server.
}

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  Horse,
  Horse.Provider.Mormot,
  Horse.Mormot.TestRoutes in '..\..\Common\Horse.Mormot.TestRoutes.pas',
  Horse.Provider.Mormot.WebResponseAdapter in '..\..\..\..\src\Horse.Provider.Mormot.WebResponseAdapter.pas',
  Horse.Provider.Mormot.WebRequestAdapter in '..\..\..\..\src\Horse.Provider.Mormot.WebRequestAdapter.pas',
  Horse.Provider.Mormot.Response in '..\..\..\..\src\Horse.Provider.Mormot.Response.pas',
  Horse.Provider.Mormot.Request in '..\..\..\..\src\Horse.Provider.Mormot.Request.pas',
  Horse.Provider.Mormot.RawResponse in '..\..\..\..\src\Horse.Provider.Mormot.RawResponse.pas',
  Horse.Provider.Mormot.RawRequest in '..\..\..\..\src\Horse.Provider.Mormot.RawRequest.pas',
  Horse.Provider.Mormot.Pool in '..\..\..\..\src\Horse.Provider.Mormot.Pool.pas';

function CtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  case dwCtrlType of
    CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT,
    CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT:
      begin
        THorse.StopListen;     // drains in-flight requests via SEC-30
        Result := True;
      end;
  else
    Result := False;
  end;
end;

begin
  SetConsoleCtrlHandler(@CtrlHandler, True);

  RegisterTestRoutes;

  WriteLn(Format('[HorseMormotTest · Delphi/Console] Listening on http://127.0.0.1:%d',
    [TEST_PORT]));
  WriteLn('Press Ctrl-C to stop.');

  THorse.Listen(TEST_PORT);

  WriteLn('[HorseMormotTest · Delphi/Console] Stopped cleanly.');
end.
