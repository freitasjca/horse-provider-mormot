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
    2. Run HorseCSTestClient.exe (from horse-provider-crosssocket/samples/tests/).
    3. Close the form to drain and stop the server.
*)

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
