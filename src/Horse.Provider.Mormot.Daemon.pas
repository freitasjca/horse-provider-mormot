unit Horse.Provider.Mormot.Daemon;

(*
  Horse mORMot Provider — Delphi cross-platform Daemon composition
  ================================================================
  Selects the mORMot2 transport for a Delphi binary running as a long-running
  OS-supervised process.

  Two OS-specific paths in the same unit:

    {$IFDEF MSWINDOWS}   THorseMormotService
                         TService base class (Vcl.SvcMgr) that auto-wires
                         ServiceStart → THorse.Listen on a worker thread,
                         ServiceStop  → THorse.StopListen + drain.
                         Use:  type TMyService = class(THorseMormotService);
                         Implements GetServiceController (SVC-CTRL-2), so a
                         descendant needs no override of its own.

    {$ELSE}              THorseMormotLinuxDaemonApp
                         Static helper class.  Run() installs POSIX signal
                         handlers and calls THorse.Listen which blocks until
                         StopListen is invoked from the signal handler.
                         Use:  THorseMormotLinuxDaemonApp.Run(Setup, Port);

  Mirrors Horse.Provider.CrossSocket.Daemon behaviour exactly.
*)

interface

uses
{$IFDEF MSWINDOWS}
  Vcl.SvcMgr,
{$ENDIF}
{$IFDEF LINUX}
  Posix.Signal,
{$ENDIF}
{$IFDEF POSIX}
  Posix.Stdlib,
{$ENDIF}
  System.SysUtils,
  System.Classes,
  Horse.Provider.Mormot;

type
  { Marker subclass }
  THorseProviderMormotDaemon = class(THorseProviderMormot);

{$IFDEF MSWINDOWS}
  { Optional TService base class.

      type TMyHorseService = class(THorseMormotService)
        procedure ServiceCreate(Sender: TObject);  // register routes here
      end;

    SVC-CTRL-2: TService.GetServiceController is abstract and TService.Main
    calls it on the SCM's thread before OnStart, so a descendant that forgot
    the override died at every start (EAbstractError, SCM error 1067) with
    nothing logged. This class implements it, forwarding to the instance
    created last. One service per process - the same limit THorse has, as it
    hosts one listener per process. A descendant that still declares its own
    override keeps working. }
  THorseMormotService = class(TService)
  private
    FPort:           Integer;
    FListenerThread: TThread;
  protected
    procedure DoServiceStart(Sender: TService; var Started: Boolean);
    procedure DoServiceStop(Sender: TService;  var Stopped: Boolean);
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
    function GetServiceController: TServiceController; override;
    property Port: Integer read FPort write FPort default 9000;
  end;
{$ENDIF MSWINDOWS}

{$IFNDEF MSWINDOWS}
  THorseMormotDaemonSetupProc = procedure;

  { Optional convenience runner for Delphi binaries cross-compiled to Linux.

      uses Horse, Horse.Provider.Mormot.Daemon;
      procedure SetupRoutes;
      begin
        THorse.Get('/ping', GetPing);
      end;
      begin
        THorseMormotLinuxDaemonApp.Run(SetupRoutes, 9000);
      end. }
  THorseMormotLinuxDaemonApp = class
  public
    class procedure Run(ASetup: THorseMormotDaemonSetupProc;
                        APort:  Integer); static;
  end;
{$ENDIF MSWINDOWS}

implementation

uses
{$IFDEF MSWINDOWS}
  Winapi.Windows,
{$ENDIF}
  Horse;

{$IFDEF MSWINDOWS}

var
  // SVC-CTRL-2: the service this process hosts. Written on the main thread
  // (Application.CreateForm, before StartServiceCtrlDispatcher), read on the
  // SCM's control thread afterwards.
  GActiveService: THorseMormotService;

procedure HorseMormotServiceController(CtrlCode: DWORD); stdcall;
begin
  if GActiveService <> nil then
    GActiveService.Controller(CtrlCode);
end;

{ THorseMormotService }

constructor THorseMormotService.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPort   := 9000;
  OnStart := DoServiceStart;
  OnStop  := DoServiceStop;
  GActiveService := Self;
end;

destructor THorseMormotService.Destroy;
begin
  if GActiveService = Self then
    GActiveService := nil;
  if Assigned(FListenerThread) then
  begin
    THorse.StopListen;
    FListenerThread.WaitFor;
    FreeAndNil(FListenerThread);
  end;
  inherited;
end;

function THorseMormotService.GetServiceController: TServiceController;
begin
  Result := HorseMormotServiceController;
end;

procedure THorseMormotService.DoServiceStart(Sender: TService;
  var Started: Boolean);
var
  LPort: Integer;
begin
  LPort := FPort;
  // Spawn a worker thread so ServiceStart returns promptly to the SCM.
  // mORMot's Listen is non-blocking in a service (IsConsole = False), so
  // the thread mostly idles after the TCP port is bound.
  FListenerThread := TThread.CreateAnonymousThread(
    procedure begin THorse.Listen(LPort); end);
  FListenerThread.FreeOnTerminate := False;
  FListenerThread.Start;
  Started := True;
end;

procedure THorseMormotService.DoServiceStop(Sender: TService;
  var Stopped: Boolean);
begin
  THorse.StopListen;
  if Assigned(FListenerThread) then
  begin
    FListenerThread.WaitFor;
    FreeAndNil(FListenerThread);
  end;
  Stopped := True;
end;

{$ENDIF MSWINDOWS}

{$IFNDEF MSWINDOWS}

procedure HandleStopSignal(ASignal: Integer); cdecl;
begin
  THorse.StopListen;
end;

{ THorseMormotLinuxDaemonApp }

class procedure THorseMormotLinuxDaemonApp.Run(
  ASetup: THorseMormotDaemonSetupProc; APort: Integer);
begin
  {$IFDEF LINUX}
  signal(SIGTERM, @HandleStopSignal);
  signal(SIGINT,  @HandleStopSignal);
  signal(SIGPIPE, TSignalHandler(SIG_IGN));
  {$ENDIF}

  if Assigned(ASetup) then
    ASetup();

  THorse.Listen(APort);
end;

{$ENDIF MSWINDOWS}

end.
