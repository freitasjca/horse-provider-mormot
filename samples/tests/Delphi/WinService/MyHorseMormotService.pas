unit MyHorseMormotService;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes,
  Vcl.SvcMgr,
  Horse,
  Horse.Provider.Mormot.Daemon,    { brings in THorseMormotService }
  Horse.Mormot.TestRoutes;

type
  { Inherits from THorseMormotService.

    The base class wires OnStart / OnStop in its constructor to its own
    DoServiceStart / DoServiceStop — which call THorse.Listen on an anonymous
    thread and swallow any exception, so failures show up as Windows SCM
    error 1067 with no diagnostic.  This descendant reassigns OnStart / OnStop
    after the base constructor returns, calls THorse.Listen synchronously
    (IsConsole=False → InternalListen returns immediately after WaitStarted),
    wraps it in try/except, and writes a file-based diagnostic log next to the
    .exe so the actual exception is visible. }
  THorseMormotTestService = class(THorseMormotService)
    procedure ServiceCreate(Sender: TObject);
  private
    procedure MyStart(Sender: TService; var Started: Boolean);
    procedure MyStop (Sender: TService; var Stopped: Boolean);
  public
    constructor Create(AOwner: TComponent); override;
  end;

var
  HorseMormotTestService: THorseMormotTestService;

{ Public diagnostic logger — callable from the .dpr too so we can log events
  that happen outside the TService instance (Application.Initialize,
  Application.Run return, unhandled exceptions, etc.). Writes to
  service-diag.log next to the .exe; thread-safe. }
procedure WriteDiag(const S: string);

implementation

uses
  System.IOUtils, System.SyncObjs;

{%CLASSGROUP 'Vcl.Controls.TControl'}

{$R *.dfm}

{ ── Diagnostic file log ─────────────────────────────────────────────────────
  Single-process critical section serialises writes from SCM / start /
  stop / pipeline threads. }
var
  GDiagLock: TCriticalSection;

procedure WriteDiag(const S: string);
var
  LFile: string;
begin
  LFile := ExtractFilePath(ParamStr(0)) + 'service-diag.log';
  GDiagLock.Acquire;
  try
    try
      TFile.AppendAllText(
        LFile,
        FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' ' + S + sLineBreak);
    except
      // Diagnostic must never crash the service
    end;
  finally
    GDiagLock.Release;
  end;
end;

{ THorseMormotTestService }

constructor THorseMormotTestService.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  // Base class set OnStart := DoServiceStart / OnStop := DoServiceStop inside
  // its own Create.  We overwrite them with our instrumented versions.
  OnStart := MyStart;
  OnStop  := MyStop;
end;

procedure THorseMormotTestService.ServiceCreate(Sender: TObject);
begin
  WriteDiag('--------------------------------------------------');
  WriteDiag('ServiceCreate entered');
  try
    Port        := TEST_PORT;             // 9010 — matches HorseCSTestClient
    Name        := 'HorseMormotTestService';
    DisplayName := 'Horse mORMot2 Integration Test Service';
    RegisterTestRoutes;
    WriteDiag(Format('Routes registered, Port=%d', [TEST_PORT]));
  except
    on E: Exception do
      WriteDiag(Format('ServiceCreate EXCEPTION %s: %s',
        [E.ClassName, E.Message]));
  end;
end;

procedure THorseMormotTestService.MyStart(Sender: TService;
  var Started: Boolean);
{$IFDEF DEBUG_WAIT_FOR_IDE}
var I: Integer;
{$ENDIF}
begin
  WriteDiag('MyStart entered');

  {$IFDEF DEBUG_WAIT_FOR_IDE}
  // Window for "Run → Attach to Process" from the Delphi IDE.
  // Enable by defining DEBUG_WAIT_FOR_IDE in Project → Options → Building →
  // Delphi Compiler → Conditional defines.
  WriteDiag('DEBUG_WAIT_FOR_IDE — sleeping 30 s for IDE attach');
  for I := 1 to 30 do
  begin
    Sleep(1000);
    ServiceThread.ProcessRequests(False);   // keep SCM happy during the wait
  end;
  WriteDiag('Wait window elapsed, proceeding');
  {$ENDIF}

  try
    WriteDiag(Format('Calling THorse.Listen(%d) synchronously', [Port]));
    // IsConsole=False inside a service, so InternalListen returns immediately
    // after THttpServer.WaitStarted — no anonymous thread needed.
    THorse.Listen(Port);
    WriteDiag('THorse.Listen returned');
    Started := True;
    WriteDiag('Started := True');
  except
    on E: Exception do
    begin
      WriteDiag(Format('MyStart EXCEPTION %s: %s',
        [E.ClassName, E.Message]));
      // Also surface to Event Viewer so "sc start" / Services.msc shows it
      LogMessage(Format('Horse start failed: %s: %s',
        [E.ClassName, E.Message]), EVENTLOG_ERROR_TYPE);
      Started := False;
    end;
  end;
end;

procedure THorseMormotTestService.MyStop(Sender: TService;
  var Stopped: Boolean);
begin
  WriteDiag('MyStop entered');
  try
    THorse.StopListen;
    WriteDiag('THorse.StopListen returned');
    Stopped := True;
  except
    on E: Exception do
    begin
      WriteDiag(Format('MyStop EXCEPTION %s: %s',
        [E.ClassName, E.Message]));
      LogMessage(Format('Horse stop failed: %s: %s',
        [E.ClassName, E.Message]), EVENTLOG_ERROR_TYPE);
      Stopped := True;  // tell SCM we stopped anyway — process is going away
    end;
  end;
end;

initialization
  GDiagLock := TCriticalSection.Create;

finalization
  GDiagLock.Free;

end.
