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
    3. Test:       run HorseCSTestClient.exe (targets port 9010).
    4. Stop:       sc stop HorseMormotTestService    (drains via SEC-30)
    5. Uninstall:  HorseMormotServiceTestServer.exe /uninstall
}

uses
  Vcl.SvcMgr,
  MyHorseService in 'MyHorseService.pas' {HorseCSTestService: TService},
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
  Horse.Mormot.TestRoutes in '..\..\Common\Horse.Mormot.TestRoutes.pas';

{$R *.RES}

begin
  // The standard Delphi Service Application boilerplate. The service class
  // (declared in MyHorseService.pas) inherits from THorseCrossSocketService
  // which inherits from Vcl.SvcMgr.TService.
  // Windows 2003 Server requires StartServiceCtrlDispatcher to be

  if not Application.DelayInitialize or Application.Installing then
    Application.Initialize;
  Application.CreateForm(THorseMormotTestService, HorseMormotTestService);
  Application.Run;
end.
