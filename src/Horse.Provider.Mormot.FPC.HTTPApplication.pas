unit Horse.Provider.Mormot.FPC.HTTPApplication;

(*
  Horse mORMot Provider — FPC HTTPApplication composition
  ========================================================
  Convenience alias for FPC projects structured around the fphttpapp
  vocabulary.  Functionally identical to the FPC Daemon shape: both are
  console-shape FPC binaries where mORMot's THttpServer owns the main loop.

  Do NOT call Application.Run — THorse.Listen owns the loop and blocks
  the main thread until StopListen is called from the signal handler.
  Two competing event loops in one process is the failure mode that
  PATCH-HORSE-1 explicitly prevents at compile time.

  THorseMormotHTTPApp.Run delegates to THorseMormotFPCDaemonApp.Run.
*)

{$MODE DELPHI}{$H+}

interface

uses
  SysUtils,
  Classes,
  Horse.Provider.Mormot,
  Horse.Provider.Mormot.FPC.Daemon;

type
  { Marker subclass }
  THorseProviderMormotFPCHTTPApplication = class(THorseProviderMormot);

  { Convenience alias of the daemon setup procedure type. }
  THorseMormotHTTPAppSetupProc = THorseMormotFPCDaemonSetupProc;

  { Optional convenience runner — delegates to THorseMormotFPCDaemonApp.Run
    because the FPC HTTPApplication shape uses the same signal-handler +
    blocking-Listen pattern.  Provided as a separate symbol for users whose
    project vocabulary is organised around HTTPApplication. }
  THorseMormotHTTPApp = class
  public
    class procedure Run(ASetup: THorseMormotHTTPAppSetupProc; APort: Integer);
  end;

implementation

class procedure THorseMormotHTTPApp.Run(
  ASetup: THorseMormotHTTPAppSetupProc; APort: Integer);
begin
  THorseMormotFPCDaemonApp.Run(ASetup, APort);
end;

end.
