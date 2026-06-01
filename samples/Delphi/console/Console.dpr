program Console;

(*
  Horse + mORMot2 Provider — Hello World Console Sample
  ======================================================

  Conditional defines (Project → Options → Conditional Defines):
    HORSE_PROVIDER_MORMOT

  Project type: Console Application.

  Demonstrates the minimal wiring needed to run a Horse HTTP server backed
  by mORMot2's THttpServer (IOCP on Windows, epoll on Linux).

  Routes
  ──────
    GET  /              → {"server":"Horse/mORMot2","engine":"IOCP/epoll"}
    GET  /ping          → pong
    POST /echo          → echoes request body as-is
    GET  /user/:id      → {"id":"<id>"}

  Run:
    curl http://127.0.0.1:9000/ping
    curl -X POST http://127.0.0.1:9000/echo -d '{"hello":"world"}'

  Press Ctrl-C or Enter to stop.
*)

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  Horse,
  Horse.Provider.Mormot;

const
  SERVER_PORT = 9000;

function CtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  case dwCtrlType of
    CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT,
    CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT:
      begin
        THorse.StopListen;
        Result := True;
      end;
  else
    Result := False;
  end;
end;

procedure RegisterRoutes;
begin
  THorse.Get('/',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send('{"server":"Horse/mORMot2","engine":"IOCP/epoll"}');
    end
  );

  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain').Send('pong');
    end
  );

  THorse.Post('/echo',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Req.Body);
    end
  );

  THorse.Get('/user/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"id":"%s"}', [Req.Params['id']]));
    end
  );
end;

begin
  SetConsoleCtrlHandler(@CtrlHandler, True);

  RegisterRoutes;

  WriteLn(Format('[Horse/mORMot2] Listening on http://127.0.0.1:%d', [SERVER_PORT]));
  WriteLn('Routes: GET /  GET /ping  POST /echo  GET /user/:id');
  WriteLn('Press Ctrl-C to stop.');

  THorse.Listen(SERVER_PORT);

  WriteLn('[Horse/mORMot2] Stopped cleanly.');
end.
