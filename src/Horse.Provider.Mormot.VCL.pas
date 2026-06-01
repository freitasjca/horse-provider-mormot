unit Horse.Provider.Mormot.VCL;

(*
  Horse mORMot Provider — Delphi VCL composition
  ================================================
  Selects the mORMot2 transport for a VCL Forms application.

  mORMot's THttpServer.WaitStarted returns immediately after the thread pool
  starts.  When IsConsole = False (always true in a VCL app), InternalListen
  returns as soon as the server is ready, leaving the VCL message loop free.

  TfrmHorseMormotVCLHost is an optional convenience base class that pre-wires
  FormCreate / FormClose to THorse.Listen / THorse.StopListen with a
  configurable Port property.  Inherit from it or wire the events manually.
*)

interface

uses
  System.SysUtils,
  System.Classes,
  Vcl.Forms,
  Horse.Provider.Mormot;

type
  { Marker subclass — inherits all transport behaviour from THorseProviderMormot.
    Useful when you need the provider type explicitly (e.g. ListenWithConfig). }
  THorseProviderMormotVCL = class(THorseProviderMormot);

  { Optional convenience form base class for VCL apps.

      type TfrmMain = class(TfrmHorseMormotVCLHost)
        // register routes in OnHorseListen or OnCreate
      end; }
  TfrmHorseMormotVCLHost = class(TForm)
  private
    FPort:          Integer;
    FAutoStart:     Boolean;
    FOnHorseListen: TNotifyEvent;
    FListening:     Boolean;
    procedure DoFormCreate(Sender: TObject);
    procedure DoFormClose(Sender: TObject; var Action: TCloseAction);
  protected
    procedure Loaded; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
    property Port:          Integer      read FPort          write FPort          default 9000;
    property AutoStart:     Boolean      read FAutoStart     write FAutoStart     default True;
    property OnHorseListen: TNotifyEvent read FOnHorseListen write FOnHorseListen;
  end;

implementation

uses
  Horse;

{ TfrmHorseMormotVCLHost }

constructor TfrmHorseMormotVCLHost.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPort      := 9000;
  FAutoStart := True;
  OnCreate   := DoFormCreate;
  OnClose    := DoFormClose;
end;

destructor TfrmHorseMormotVCLHost.Destroy;
begin
  if FListening then
    THorse.StopListen;
  inherited;
end;

procedure TfrmHorseMormotVCLHost.Loaded;
begin
  inherited;
end;

procedure TfrmHorseMormotVCLHost.DoFormCreate(Sender: TObject);
begin
  if not FAutoStart then Exit;
  if Assigned(FOnHorseListen) then
    FOnHorseListen(Self);
  THorse.Listen(FPort);   // non-blocking in a VCL app (IsConsole = False)
  FListening := True;
end;

procedure TfrmHorseMormotVCLHost.DoFormClose(Sender: TObject;
  var Action: TCloseAction);
begin
  if FListening then
  begin
    THorse.StopListen;    // graceful drain via SEC-30
    FListening := False;
  end;
end;

end.
