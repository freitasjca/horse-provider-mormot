unit Main.Form;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,
  System.Classes, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.StdCtrls,
  Horse,
  Horse.Provider.Mormot.VCL,
  Horse.Mormot.TestRoutes;

type
  { Inherits from TfrmHorseMormotVCLHost (the convenience base class in
    Horse.Provider.Mormot.VCL). The base form auto-wires FormCreate /
    FormClose to THorse.Listen / THorse.StopListen. We override
    OnHorseListen to register the test routes BEFORE Listen binds. }
  TfrmHorseMormotTestVCL = class(TfrmHorseMormotVCLHost)
    lblStatus: TLabel;
    procedure OnRegisterRoutes(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
  end;

var
  frmHorseMormotTestVCL: TfrmHorseMormotTestVCL;

implementation

{$R *.dfm}

constructor TfrmHorseMormotTestVCL.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Port := TEST_PORT;             // 9010 — matches HorseCSTestClient
  OnHorseListen := OnRegisterRoutes;
  Caption := Format('Horse mORMot2 VCL Test Server — port %d', [TEST_PORT]);
end;

procedure TfrmHorseMormotTestVCL.OnRegisterRoutes(Sender: TObject);
begin
  RegisterTestRoutes;
  if Assigned(lblStatus) then
    lblStatus.Caption := Format('Listening on http://127.0.0.1:%d  ·  '
      + 'run HorseCSTestClient to exercise. Close this form to stop.',
      [Port]);
end;

end.
