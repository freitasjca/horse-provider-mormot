unit MyHorseService;


interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  System.Classes,
  Vcl.SvcMgr,
  Horse.Provider.Mormot.Daemon,    { brings in THorseMormotService }
  Horse.Mormot.TestRoutes;

type
  { Inherits from THorseCrossSocketService (the PATCH-HORSE-2 convenience
    base class). The base service auto-wires ServiceStart / ServiceStop —
    we only need to set Port and register routes. ServiceCreate fires
    before ServiceStart, which is where the routes get installed.

    The Port property defaults to 9000 in the base class; we override to
    9010 here so the shared HorseCSTestClient targets the right port. }
  THorseMormotTestService = class(THorseMormotService)
    procedure ServiceCreate(Sender: TObject);
  private
    { Private declarations }
  public
    function GetServiceController: TServiceController; override;
    { Public declarations }
  end;

var
  HorseMormotTestService: THorseMormotTestService;

implementation

{$R *.dfm}

procedure ServiceController(CtrlCode: DWord); stdcall;
begin
  HorseMormotTestService.Controller(CtrlCode);
end;

function THorseMormotTestService.GetServiceController: TServiceController;
begin
  Result := ServiceController;
end;

procedure THorseMormotTestService.ServiceCreate(Sender: TObject);
begin
  Port := TEST_PORT;             // 9010 — matches HorseMormotTestClient.dpr
  Name        := 'HorseMormotService';
  DisplayName := 'Horse Mormot Integration Test Service';
  RegisterTestRoutes;
end;

end.
