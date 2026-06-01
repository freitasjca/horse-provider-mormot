program HorseMormotTestServer;

{
  Horse + mORMot2 Provider — Integration Test Server (Lazarus · Console shape)
  =============================================================================

  Conditional defines (Project → Project Options → Compiler Options →
  Custom Options):
    -dHORSE_PROVIDER_MORMOT   (future, once Horse.pas routes this define)

  Project type: Lazarus console program (Application class: Console).

  mORMot2 supports FPC / Lazarus. When IsConsole = True, mORMot's
  InternalListen blocks the main thread; fpSignal handlers unblock it on
  SIGTERM / SIGINT.

  Routes: see ..\..\Common\Horse.Mormot.TestRoutes.pas — same 32 surfaces
  the shared HorseCSTestClient exercises.

  Run sequence:
    1. lazbuild HorseMormotTestServer.lpi  (or compile in the IDE)
    2. ./HorseMormotTestServer
    3. From a Delphi or Lazarus host, run HorseCSTestClient.
    4. Ctrl-C / SIGTERM for a clean shutdown.
}

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  SysUtils,
  Horse,
  Horse.Provider.Mormot,
  Horse.Mormot.TestRoutes;

{$IFDEF UNIX}
procedure HandleStopSignal(ASignal: cint); cdecl;
begin
  THorse.StopListen;
end;
{$ENDIF}

begin
  {$IFDEF UNIX}
  fpSignal(SIGTERM, @HandleStopSignal);
  fpSignal(SIGINT,  @HandleStopSignal);
  {$ENDIF}

  RegisterTestRoutes;

  WriteLn(Format('[HorseMormotTest · Lazarus/Console] Listening on http://127.0.0.1:%d',
    [TEST_PORT]));
  WriteLn('Press Ctrl-C to stop.');

  THorse.Listen(TEST_PORT);

  WriteLn('[HorseMormotTest · Lazarus/Console] Stopped cleanly.');
end.
