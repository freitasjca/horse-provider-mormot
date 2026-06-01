program HorseMormotTestServer;

{
  Horse + mORMot2 Provider — Integration Test Server (Delphi · Console shape)
  ============================================================================

  Conditional defines (Project → Options → Conditional Defines):
    HORSE_PROVIDER_MORMOT     (activates mORMot2 transport in Horse.pas)

  Project type: Console Application.

  mORMot's THttpServer uses IOCP (Windows) / epoll (Linux) and manages its
  own thread pool (default: 32 threads).  When IsConsole = True, InternalListen
  blocks the main thread on a TEvent until StopListen signals it.
  SetConsoleCtrlHandler unblocks it on Ctrl-C / Ctrl-Break / SCM stop.

  Routes: see Common\Horse.Mormot.TestRoutes.pas — same 32 surfaces the
  shared HorseCSTestClient.dpr exercises.  All per-shape servers in this tree
  register exactly the same routes so the client is interchangeable.

  Run sequence:
    1. Start this server (or HorseMormotTestServer.exe).
    2. Run HorseCSTestClient.exe (from horse-provider-crosssocket/samples/tests/).
    3. Point the client at port 9010 (TEST_PORT in Horse.Mormot.TestRoutes).
    4. Expect the same pass/fail counts as the CrossSocket console server.
}

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  Horse,
  Horse.Provider.Mormot,
  Horse.Mormot.TestRoutes in 'Common\Horse.Mormot.TestRoutes.pas';

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
