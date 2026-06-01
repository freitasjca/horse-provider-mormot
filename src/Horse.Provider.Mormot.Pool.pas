unit Horse.Provider.Mormot.Pool;

(*
  Horse mORMot Provider — Context Object Pool
  ============================================
  Pre-allocates THorseContext objects to avoid allocating TDictionary
  collections on every request under load.

  ── Prerequisite: Horse fork patches must be applied ───────────────────────
  This unit depends on two patches to the Horse fork (horse-fork/src/):

    PATCH-REQ-1 (Horse.Request.pas)
      constructor THorseRequest.Create;  overload;
      Parameterless constructor for pool warm-up.

    PATCH-REQ-2 (Horse.Request.pas)
      procedure THorseRequest.Clear;
      Resets all internal state.  Sets FBody := nil (safe, no-op for mORMot
      since FBody is never assigned to a live stream on this path).

    PATCH-RES-2 (Horse.Response.pas)
      procedure THorseResponse.Clear;
      Sets FWebResponse := nil, clears FCSBody and other shadow fields.

  ── mORMot-specific ownership note ─────────────────────────────────────────
  Unlike CrossSocket, the mORMot provider does NOT assign a TStream to
  THorseRequest.FBody.  The request body is a RawByteString held entirely
  inside mORMot's THttpServerRequestAbstract (owned by mORMot) and exposed
  to Horse via SetBodyString (PATCH-REQ-9) as a cached string.

  FBody is therefore always nil on this path, and THorseRequest.Clear sets
  it to nil without freeing — which is safe and correct.

  ── Security tags ───────────────────────────────────────────────────────────
  [SEC-7]  Complete Reset — delegates to patched Clear methods.
  [SEC-8]  DEBUG double-acquire/release guard.
  [SEC-9]  FBody ownership — always nil on mORMot path; Clear is still used
           (never Body(nil)) for consistency with the CrossSocket pool.
  [SEC-10] Pool counter uses TInterlocked for the hot-path IdleCount read.
  [SEC-11] WarmUp runs outside the lock.

  Dual-compilation: Delphi and FPC.
*)

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections,
{$ELSE}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
{$ENDIF}
  Horse.Request,
  Horse.Response;

const
  POOL_MAX_SIZE    = 512;
  POOL_WARMUP_SIZE = 32;

type
  THorseContext = class
  private
    FRequest:  THorseRequest;
    FResponse: THorseResponse;
    FInUse:    Boolean;   // [SEC-8] detects double-acquire / double-release
  public
    constructor Create;
    destructor  Destroy; override;

    { [SEC-7] Guaranteed complete Reset — delegates to patched Clear methods }
    procedure Reset;

    property Request:  THorseRequest  read FRequest;
    property Response: THorseResponse read FResponse;
    property InUse:    Boolean        read FInUse write FInUse;
  end;

  THorseContextPool = class
  private
    class var FPool:      TStack<THorseContext>;
    class var FLock:      TCriticalSection;
    class var FIdleCount: Integer;   // [SEC-10] written under lock, read via TInterlocked

    class procedure InternalWarmUp;
  public
    class constructor Create;
    class destructor  Destroy;

    class function  Acquire: THorseContext;
    class procedure Release(AContext: THorseContext);
    class function  IdleCount: Integer; inline;
  end;

implementation

{ THorseContext }

constructor THorseContext.Create;
begin
  inherited Create;
  // PATCH-REQ-1: parameterless constructor — FWebRequest is nil.
  // TMormotRequestBridge.Populate writes to shadow fields via AHorseReq.Populate().
  FRequest  := THorseRequest.Create;
  FResponse := THorseResponse.Create(nil);
  FInUse    := False;
end;

destructor THorseContext.Destroy;
begin
  // [SEC-9] FBody is never assigned a live stream on the mORMot path —
  // it is always nil.  Call Clear (PATCH-REQ-2) rather than Body(nil) for
  // consistency with the CrossSocket pool; Clear sets FBody := nil directly
  // without calling Free, so THorseRequest.Destroy sees FBody = nil.
  FRequest.Clear;
  FRequest.Free;
  FResponse.Free;
  inherited Destroy;
end;

procedure THorseContext.Reset;
begin
  // ── [SEC-7][SEC-9] Delegate to patched Clear methods ─────────────────────
  // THorseRequest.Clear (PATCH-REQ-2) wipes all fields:
  //   FBody        := nil  (direct assignment — not via Body(nil) setter)
  //   FBodyString  := ''   (PATCH-REQ-9 cache cleared)
  //   FSession, FWebRequest, FCSRawWebRequest → nil
  //   FHeaders.Dictionary.Clear  (in-place — avoids reallocation)
  //   FQuery, FContentFields, FCookie → FreeAndNil (lazy rebuild)
  //   FParams.Dictionary.Clear
  //   FSessions → FreeAndNil + THorseSessions.Create
  FRequest.Clear;

  // THorseResponse.Clear (PATCH-RES-2) wipes:
  //   FWebResponse, FCSBody, FCSRawWebResponse → nil / ''
  //   FCustomHeaders.Clear (in-place)
  FResponse.Clear;

  FInUse := False;
end;

{ THorseContextPool }

class constructor THorseContextPool.Create;
begin
  FPool      := TStack<THorseContext>.Create;
  FLock      := TCriticalSection.Create;
  FIdleCount := 0;
  // [SEC-11] WarmUp outside the lock — avoids re-entrancy
  InternalWarmUp;
end;

class destructor THorseContextPool.Destroy;
var
  Ctx: THorseContext;
begin
  FLock.Acquire;
  try
    while FPool.Count > 0 do
    begin
      Ctx := FPool.Pop;
      Ctx.Free;
    end;
    FIdleCount := 0;
  finally
    FLock.Release;
  end;
  FPool.Free;
  FLock.Free;
end;

class procedure THorseContextPool.InternalWarmUp;
var
  I:     Integer;
  Batch: array[0..POOL_WARMUP_SIZE - 1] of THorseContext;
begin
  for I := 0 to POOL_WARMUP_SIZE - 1 do
    Batch[I] := THorseContext.Create;

  FLock.Acquire;
  try
    for I := 0 to POOL_WARMUP_SIZE - 1 do
    begin
      FPool.Push(Batch[I]);
      Inc(FIdleCount);
    end;
  finally
    FLock.Release;
  end;
end;

class function THorseContextPool.Acquire: THorseContext;
begin
  FLock.Acquire;
  try
    if FPool.Count > 0 then
    begin
      Result := FPool.Pop;
      Dec(FIdleCount);
    end
    else
      Result := THorseContext.Create;
  finally
    FLock.Release;
  end;

  {$IFDEF DEBUG}
  Assert(not Result.InUse,
    'THorseContextPool.Acquire: context already marked in-use (double-acquire?)');
  {$ENDIF}
  Result.InUse := True;
end;

class procedure THorseContextPool.Release(AContext: THorseContext);
begin
  if AContext = nil then Exit;

  {$IFDEF DEBUG}
  Assert(AContext.InUse,
    'THorseContextPool.Release: context was not acquired (double-release?)');
  {$ENDIF}

  try
    AContext.Reset;
  except
    AContext.Free;
    Exit;
  end;

  FLock.Acquire;
  try
    if FIdleCount < POOL_MAX_SIZE then
    begin
      FPool.Push(AContext);
      Inc(FIdleCount);
    end
    else
      AContext.Free;
  finally
    FLock.Release;
  end;
end;

class function THorseContextPool.IdleCount: Integer;
begin
  // [SEC-10] Atomic read — safe from any thread without the lock
  Result := TInterlocked.CompareExchange(FIdleCount, 0, 0);
end;

end.
