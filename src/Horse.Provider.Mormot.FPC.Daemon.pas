unit Horse.Provider.Mormot.FPC.Daemon;

(*
  Horse mORMot Provider — FPC Linux daemon composition
  =====================================================
  Selects the mORMot2 transport for an FPC console-shape binary supervised
  by systemd (or any process supervisor that delivers SIGTERM on stop).

  THorseMormotFPCDaemonApp.Run installs fpSignal(SIGTERM) and fpSignal(SIGINT)
  handlers that call THorse.StopListen, then invokes ASetup to register routes,
  then calls THorse.Listen(APort) which blocks until a signal arrives.

  SIGPIPE is ignored — mORMot's THttpServer handles client-side resets
  internally; the default action (terminate) would crash the daemon on a
  peer drop.

  Mirrors Horse.Provider.CrossSocket.FPC.Daemon behaviour exactly.
*)

{$MODE DELPHI}{$H+}

interface

uses
  SysUtils,
  Classes,
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  Horse.Provider.Mormot;

type
  { Marker subclass }
  THorseProviderMormotFPCDaemon = class(THorseProviderMormot);

  { User-provided setup procedure: register routes, middleware, config. }
  THorseMormotFPCDaemonSetupProc = procedure;

  { Optional convenience runner.

      uses Horse, Horse.Provider.Mormot.FPC.Daemon;
      procedure SetupRoutes;
      begin
        THorse.Get('/ping', @GetPing);
      end;
      begin
        THorseMormotFPCDaemonApp.Run(@SetupRoutes, 9000);
      end.

    Run installs SIGTERM + SIGINT handlers that call THorse.StopListen,
    invokes ASetup to register routes, then calls THorse.Listen(APort)
    which blocks until a signal arrives. }
  THorseMormotFPCDaemonApp = class
  public
    class procedure Run(ASetup: THorseMormotFPCDaemonSetupProc; APort: Integer);
  end;

implementation

uses
  Horse;

{$IFDEF UNIX}
procedure HandleStopSignal(ASignal: cint); cdecl;
begin
  // POSIX signal handlers must be reentrant-safe.  THorse.StopListen sets a
  // manual-reset event — safe to call from a signal context on Linux glibc +
  // FPC RTL.
  THorse.StopListen;
end;
{$ENDIF}

class procedure THorseMormotFPCDaemonApp.Run(
  ASetup: THorseMormotFPCDaemonSetupProc; APort: Integer);
begin
  {$IFDEF UNIX}
  fpSignal(SIGTERM, @HandleStopSignal);
  fpSignal(SIGINT,  @HandleStopSignal);
  fpSignal(SIGPIPE, signalhandler(SIG_IGN));
  {$ENDIF}

  if Assigned(ASetup) then
    ASetup();

  THorse.Listen(APort);   // blocks until StopListen unblocks it
end;

end.
