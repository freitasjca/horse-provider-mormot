unit Horse.Provider.Mormot.FPC.LCL;

(*
  Horse mORMot Provider — FPC / Lazarus LCL composition
  ======================================================
  Selects the mORMot2 transport for a Lazarus LCL GUI application.

  mORMot's THttpServer.WaitStarted returns immediately after the thread pool
  starts.  When IsConsole = False (always true in an LCL Forms application),
  InternalListen returns as soon as the server is ready, leaving the LCL
  message loop free.

  TfrmHorseMormotLCLHost is the Lazarus mirror of TfrmHorseMormotVCLHost.
  Inherit from it or wire FormCreate / FormClose manually.
*)

{$MODE DELPHI}{$H+}

interface

uses
  SysUtils,
  Classes,
  Forms,
  Horse.Provider.Mormot;

type
  { Marker subclass }
  THorseProviderMormotFPCLCL = class(THorseProviderMormot);

  { Optional convenience LCL form base class.

      type TfrmMain = class(TfrmHorseMormotLCLHost)
        // register routes in OnHorseListen or OnCreate
      end; }
  TfrmHorseMormotLCLHost = class(TForm)
  private
    FPort:          Integer;
    FAutoStart:     Boolean;
    FOnHorseListen: TNotifyEvent;
    FListening:     Boolean;
    procedure DoFormCreate(Sender: TObject);
    procedure DoFormClose(Sender: TObject; var CloseAction: TCloseAction);
  protected
    procedure Loaded; override;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor  Destroy; override;
    property Port:          Integer      read FPort          write FPort          default 9000;
    property AutoStart:     Boolean      read FAutoStart     write FAutoStart     default True;
    property OnHorseListen: TNotifyEvent read FOnHorseListen write FOnHorseListen;
  end;

implementation

uses
  Horse;

{ TfrmHorseMormotLCLHost }

constructor TfrmHorseMormotLCLHost.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  FPort      := 9000;
  FAutoStart := True;
  OnCreate   := @DoFormCreate;
  OnClose    := @DoFormClose;
end;

destructor TfrmHorseMormotLCLHost.Destroy;
begin
  if FListening then
    THorse.StopListen;
  inherited;
end;

procedure TfrmHorseMormotLCLHost.Loaded;
begin
  inherited;
end;

procedure TfrmHorseMormotLCLHost.DoFormCreate(Sender: TObject);
begin
  if not FAutoStart then Exit;
  if Assigned(FOnHorseListen) then
    FOnHorseListen(Self);
  THorse.Listen(FPort);   // non-blocking in an LCL app (IsConsole = False)
  FListening := True;
end;

procedure TfrmHorseMormotLCLHost.DoFormClose(Sender: TObject;
  var CloseAction: TCloseAction);
begin
  if FListening then
  begin
    THorse.StopListen;    // graceful drain via SEC-30
    FListening := False;
  end;
end;

end.
