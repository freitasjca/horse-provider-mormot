program HorseMormotVCLTestServer;

(*
  Horse + mORMot2 Provider — Integration Test Server (Delphi · VCL shape)
  ========================================================================

  Project type: VCL Forms Application.  Do NOT add {$APPTYPE CONSOLE} to
  this .dpr — that would force IsConsole = True and block the UI when
  Listen runs.  When IsConsole = False (always true in a VCL app) mORMot's
  InternalListen returns as soon as the server is ready, leaving the VCL
  message loop free.

  TfrmHorseMormotTestVCL inherits from TfrmHorseMormotVCLHost
  (Horse.Provider.Mormot.VCL). The base form auto-wires:
    FormCreate → THorse.Listen(Port)    (non-blocking in VCL app)
    FormClose  → THorse.StopListen     (graceful drain via SEC-30)
  Routes are registered via the OnHorseListen event, which fires before
  Listen binds.

  Run sequence:
    1. Start this VCL app — the form shows; mORMot's thread pool runs in
       the background while the VCL message loop keeps the form responsive.
    2. Run HorseMormotTestClient.exe (samples/tests/, built by build-tests-dcc.bat).
       Confirm the transport first: curl -sI http://127.0.0.1:9010/ping must
       show Server: unknown and X-Frame-Options: DENY (the provider's banner
       and security headers; Indy sends neither).
    3. Close the form to drain and stop the server.
*)

// SAMPLE-DEFINE-1 (2026-10-09): every server in this tree starts through
// THorse.Listen, and THorse is whatever provider Horse.pas selects. Without
// HORSE_PROVIDER_MORMOT that is Horse's default (Indy on Delphi): the mORMot
// units still compile, but the sample serves on Indy and a green client run
// proves nothing about this provider. Fail the build instead.
{$IF NOT DEFINED(HORSE_PROVIDER_MORMOT)}
  {$MESSAGE FATAL 'Define HORSE_PROVIDER_MORMOT in Project Options, Conditional defines, All configurations, then Build. Without it this sample serves on Indy, not mORMot.'}
{$IFEND}

uses
  Vcl.Forms,
  Horse,
  Horse.Provider.Mormot,
  Horse.Provider.Mormot.VCL,
  Horse.Mormot.TestRoutes in '..\..\Common\Horse.Mormot.TestRoutes.pas',
  Main.Form in 'Main.Form.pas' {frmHorseMormotTestVCL};

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmHorseMormotTestVCL, frmHorseMormotTestVCL);
  Application.Run;
end.
