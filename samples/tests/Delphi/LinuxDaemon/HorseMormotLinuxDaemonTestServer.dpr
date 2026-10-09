program HorseMormotLinuxDaemonTestServer;

(*
  Horse + mORMot2 Provider — Integration Test Server (Delphi · Linux daemon shape)
  ==================================================================================

  Project target: Linux64. Console application (a daemon on Linux is a
  long-running console binary supervised by systemd).

  Same shape as Delphi/WinService — the cross-platform
  Horse.Provider.Mormot.Daemon.pas selects the appropriate helper at
  compile time:
    {$IFDEF MSWINDOWS} → THorseMormotService          (TService base)
    {$ELSE}            → THorseMormotLinuxDaemonApp    (POSIX runner)

  THorseMormotLinuxDaemonApp.Run installs SIGTERM / SIGINT handlers, ignores
  SIGPIPE, runs the SetupRoutes callback, then calls the blocking
  THorse.Listen. SIGTERM signals Stop → drain → exit 0.

  Routes: see ..\..\Common\Horse.Mormot.TestRoutes.pas — same 32 surfaces
  HorseMormotTestClient.dpr exercises.

  Run sequence (Linux):
    1. Build for Linux64, copy binary + mORMot2 shared libs to the host.
    2. Install the systemd unit file (see ../../README.md §Linux daemon).
    3. sudo systemctl start horsemormot-test-daemon
    4. Run HorseMormotTestClient from any host that can reach port 9010.
    5. sudo systemctl stop horsemormot-test-daemon  (SIGTERM → clean drain)
*)

{$APPTYPE CONSOLE}

// SAMPLE-DEFINE-1 (2026-10-09): every server in this tree starts through
// THorse.Listen, and THorse is whatever provider Horse.pas selects. Without
// HORSE_PROVIDER_MORMOT that is Horse's default (Indy on Delphi): the mORMot
// units still compile, but the sample serves on Indy and a green client run
// proves nothing about this provider. Fail the build instead.
{$IF NOT DEFINED(HORSE_PROVIDER_MORMOT)}
  {$MESSAGE FATAL 'Define HORSE_PROVIDER_MORMOT in Project Options, Conditional defines, All configurations, then Build. Without it this sample serves on Indy, not mORMot.'}
{$IFEND}

uses
  System.SysUtils,
  Horse,
  Horse.Provider.Mormot,
  Horse.Provider.Mormot.Daemon,
  Horse.Mormot.TestRoutes in '..\..\Common\Horse.Mormot.TestRoutes.pas';

procedure SetupRoutes;
begin
  RegisterTestRoutes;
  WriteLn(Format('[HorseMormotTest · Delphi/LinuxDaemon] Listening on http://0.0.0.0:%d',
    [TEST_PORT]));
  WriteLn('Send SIGTERM (systemctl stop) for a clean shutdown.');
end;

begin
{$IFDEF LINUX}
  { Linux path — THorseMormotLinuxDaemonApp installs POSIX signal handlers
    and calls blocking THorse.Listen(APort) for us. }
  THorseMormotLinuxDaemonApp.Run(SetupRoutes, TEST_PORT);
{$ELSE}
  { For Windows-Service builds use Delphi/WinService/ instead — same defines,
    different target. This .dpr is intentionally Linux-targeted. }
  WriteLn('[HorseMormotTest · Delphi/LinuxDaemon] This project must be built '
        + 'for Linux64. For Windows-Service builds, open Delphi/WinService/.');
  ExitCode := 1;
{$ENDIF}
  WriteLn('[HorseMormotTest · Delphi/LinuxDaemon] Stopped cleanly.');
end.
