program HorseMormotDaemonTestServer;

{
  Horse + mORMot2 Provider — Integration Test Server (Lazarus · Daemon shape)
  ============================================================================

  Conditional defines (Project → Project Options → Compiler Options →
  Custom Options):
    -dHORSE_PROVIDER_MORMOT   (future, once Horse.pas routes this define)

  Project type: Lazarus console program targeting Linux / macOS / BSD.

  THorseMormotLinuxDaemonApp.Run (in Horse.Provider.Mormot.Daemon) installs
  POSIX signal handlers (SIGTERM, SIGINT → StopListen; SIGPIPE → ignored),
  calls the SetupRoutes callback, then calls the blocking THorse.Listen.

  The entire `program` body collapses to a single Run() call after
  registering the routes — same style as THorseCrossSocketDaemonApp.Run
  in the CrossSocket provider.

  Routes: see ..\..\Common\Horse.Mormot.TestRoutes.pas.

  Run sequence:
    1. lazbuild HorseMormotDaemonTestServer.lpi
    2. Install via systemd (see ../../README.md §Linux daemon).
    3. sudo systemctl start horsemormot-lazarus-daemon-test
    4. Run HorseCSTestClient; expect the same pass/fail as Console shape.
    5. sudo systemctl stop horsemormot-lazarus-daemon-test (SIGTERM clean drain)
}

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}

uses
  SysUtils,
  Horse,
  Horse.Provider.Mormot,
  Horse.Provider.Mormot.Daemon,
  Horse.Mormot.TestRoutes;

procedure SetupRoutes;
begin
  RegisterTestRoutes;
  WriteLn(Format('[HorseMormotTest · Lazarus/Daemon] Listening on http://0.0.0.0:%d',
    [TEST_PORT]));
  WriteLn('Send SIGTERM (systemctl stop) for a clean shutdown.');
end;

begin
  THorseMormotLinuxDaemonApp.Run(@SetupRoutes, TEST_PORT);
  WriteLn('[HorseMormotTest · Lazarus/Daemon] Stopped cleanly.');
end.
