program HorseMormotServiceTestServer;

{
  Horse + mORMot2 Provider — Integration Test Server (Delphi · Windows Service)
  ==============================================================================

  Project type: Service Application (File - New - Other - Service Application).

  THorseMormotTestService inherits from THorseMormotService
  (Horse.Provider.Mormot.Daemon). The descendant overrides OnStart/OnStop to
  call THorse.Listen / StopListen synchronously inside try/except, and writes
  a diagnostic log (service-diag.log) next to the .exe so SCM error 1067 is
  no longer opaque.

  This .dpr is instrumented with WriteDiag calls around every lifecycle step
  so a startup failure is visible even when it happens before ServiceCreate
  or after Application.Run returns. An Application.OnException handler
  captures any otherwise-silent unhandled exception in the main thread.

  Run sequence:
    1. Install:    HorseMormotServiceTestServer.exe /install
    2. Start:      sc start HorseMormotTestService
    3. Test:       run HorseMormotTestClient.exe (targets port 9010).
    4. Stop:       sc stop HorseMormotTestService    (drains via SEC-30)
    5. Uninstall:  HorseMormotServiceTestServer.exe /uninstall
}

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
  Vcl.SvcMgr,
  MyHorseMormotService in 'MyHorseMormotService.pas' {HorseMormotTestService: TService},
  Horse.Mormot.TestRoutes in '..\..\Common\Horse.Mormot.TestRoutes.pas',
  Horse.Provider.Mormot.Config in '..\..\..\..\src\Horse.Provider.Mormot.Config.pas',
  Horse.Provider.Mormot.Daemon in '..\..\..\..\src\Horse.Provider.Mormot.Daemon.pas',
  Horse.Provider.Mormot in '..\..\..\..\src\Horse.Provider.Mormot.pas',
  Horse.Provider.Mormot.Pool in '..\..\..\..\src\Horse.Provider.Mormot.Pool.pas',
  Horse.Provider.Mormot.RawRequest in '..\..\..\..\src\Horse.Provider.Mormot.RawRequest.pas',
  Horse.Provider.Mormot.RawResponse in '..\..\..\..\src\Horse.Provider.Mormot.RawResponse.pas',
  Horse.Provider.Mormot.Request in '..\..\..\..\src\Horse.Provider.Mormot.Request.pas',
  Horse.Provider.Mormot.Response in '..\..\..\..\src\Horse.Provider.Mormot.Response.pas',
  Horse.Provider.Mormot.VCL in '..\..\..\..\src\Horse.Provider.Mormot.VCL.pas',
  Horse.Provider.Mormot.WebRequestAdapter in '..\..\..\..\src\Horse.Provider.Mormot.WebRequestAdapter.pas',
  Horse.Provider.Mormot.WebResponseAdapter in '..\..\..\..\src\Horse.Provider.Mormot.WebResponseAdapter.pas',
  // Horse core units, found through the horse\src search path. They were listed
  // with an in-path into this repo's src\, where they have never existed (F1026).
  Horse.Provider.RawAdapters,
  Horse.Provider.RawInterfaces;

{$R *.res}

begin
  // -- Phase 1: process is alive, before any VCL/SCM machinery ---------------
  try
    WriteDiag('==================================================');
    WriteDiag(Format('Process launched — CmdLine="%s"', [CmdLine]));
    WriteDiag(Format('Exe="%s"', [ParamStr(0)]));
  except
    // never let diagnostic logging itself crash the launch
  end;

  try
    // -- Phase 2: standard Vcl.SvcMgr boilerplate --------------------------
    if not Application.DelayInitialize or Application.Installing then
    begin
      WriteDiag('Calling Application.Initialize');
      Application.Initialize;
      WriteDiag('Application.Initialize returned');
    end
    else
      WriteDiag('Skipping Application.Initialize (delayed)');

    WriteDiag('Calling Application.CreateForm');
    Application.CreateForm(THorseMormotTestService, HorseMormotTestService);
    WriteDiag('Application.CreateForm returned');

    // Note: neither Vcl.SvcMgr.TServiceApplication nor TService exposes an
    // OnException event. Exception coverage is provided by:
    //   - the outer try/except below (catches main-thread exceptions in
    //     Application.Initialize / CreateForm / Run / StartServiceCtrlDispatcher)
    //   - try/except inside MyStart / MyStop in MyHorseMormotService.pas
    //   - try/except inside ServiceCreate in MyHorseMormotService.pas

    WriteDiag('Calling Application.Run (StartServiceCtrlDispatcher)');
    Application.Run;
    WriteDiag('Application.Run returned — process exiting cleanly');
  except
    on E: Exception do
      WriteDiag(Format('UNHANDLED EXCEPTION in main: %s: %s',
        [E.ClassName, E.Message]));
  end;
end.
