program HorseMormotDemo;

(*
  Horse + mORMot2 Provider — Demo Server
  ========================================
  Compila com: Horse padrao (HashLoad) + mORMot2
  Sem dependencia de Horse fork patcheado.

  Rotas: /ping  /echo  /headers  /query  /user/:id  /cookie
         /server/info  /

  Teste: curl http://127.0.0.1:9000/ping
*)

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.JSON,
  Horse,
  Horse.Commons,
  Horse.Callback,
  Horse.Provider.Mormot;

const
  SERVER_PORT = 9000;

procedure RegisterRoutes;
begin
  // ── Healthcheck ───────────────────────────────────────────────────
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
    begin
      Res.Send('pong');
    end);

  // ── Raiz ──────────────────────────────────────────────────────────
  THorse.Get('/',
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send('{"server":"Horse/mORMot2","engine":"IOCP/epoll"}');
    end);

  // ── Echo JSON ─────────────────────────────────────────────────────
  THorse.Post('/echo',
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Req.Body);
    end);

  // ── Headers dump ──────────────────────────────────────────────────
  THorse.Get('/headers',
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
    var
      LJson: TJSONObject;
      LEnum: TPair<string, string>;
    begin
      LJson := TJSONObject.Create;
      try
        for LEnum in Req.Headers.Dictionary do
          LJson.AddPair(LEnum.Key, LEnum.Value);
        Res.ContentType('application/json; charset=utf-8')
           .Send(LJson.ToJSON);
      finally
        LJson.Free;
      end;
    end);

  // ── Query params ──────────────────────────────────────────────────
  THorse.Get('/query',
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
    var
      LJson: TJSONObject;
      LPair: TPair<string, string>;
    begin
      LJson := TJSONObject.Create;
      try
        for LPair in Req.Query.Dictionary do
          LJson.AddPair(LPair.Key, LPair.Value);
        Res.ContentType('application/json; charset=utf-8')
           .Send(LJson.ToJSON);
      finally
        LJson.Free;
      end;
    end);

  // ── Path params ───────────────────────────────────────────────────
  THorse.Get('/user/:id',
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"id":"%s"}', [Req.Params['id']]));
    end);

  // ── PUT ───────────────────────────────────────────────────────────
  THorse.Put('/user/:id',
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"id":"%s","body":%s}',
           [Req.Params['id'], Req.Body]));
    end);

  // ── DELETE ────────────────────────────────────────────────────────
  THorse.Delete('/user/:id',
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"id":"%s","deleted":true}',
           [Req.Params['id']]));
    end);

  // ── Cookies ───────────────────────────────────────────────────────
  THorse.Get('/cookie',
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
    var
      LJson: TJSONObject;
      LPair: TPair<string, string>;
    begin
      LJson := TJSONObject.Create;
      try
        for LPair in Req.Cookie.Dictionary do
          LJson.AddPair(LPair.Key, LPair.Value);
        Res.AddHeader('Set-Cookie',
          Format('demo=%s; Path=/; HttpOnly; SameSite=Strict',
            [TGUID.NewGuid.ToString]));
        Res.ContentType('application/json; charset=utf-8')
           .Send(LJson.ToJSON);
      finally
        LJson.Free;
      end;
    end);

  // ── Server info ───────────────────────────────────────────────────
  THorse.Get('/server/info',
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format(
           '{"engine":"mORMot2","port":%d,"provider":"THorseProviderMormot"}',
           [SERVER_PORT]));
    end);
end;

begin
  try
    RegisterRoutes;
    WriteLn(Format('[Horse/mORMot2] Starting on http://127.0.0.1:%d ...', [SERVER_PORT]));
    WriteLn('Routes: /ping /echo /headers /query /user/:id /cookie /server/info');
    WriteLn('Press ENTER to stop...');
    THorseProviderMormot.Listen(SERVER_PORT);
  except
    on E: Exception do
    begin
      WriteLn('Fatal: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
