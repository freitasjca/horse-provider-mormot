unit Horse.Provider.Mormot.RawRequest;

(*
  mORMot2 IHorseRawRequest implementation
  =========================================
  Wraps THttpServerRequestAbstract in ~15 methods.
  The generic TInterfacedWebRequest adapter (Horse.Provider.RawAdapters)
  delegates here to build a full TWebRequest compatible with all middleware.

  Key differences from CrossSocket:
  - mORMot uses a single THttpServerRequestAbstract for both request and response
  - Headers are stored as a single CRLF-delimited RawUtf8 string (InHeaders)
  - Body is a RawByteString (InContent), not a TStream
  - All string properties use RawUtf8 (UTF-8); convert with Utf8ToString

  Dual-compilation: Delphi and FPC share the same implementation.
*)

{$IF DEFINED(FPC)}
{$MODE DELPHI}{$H+}
{$ENDIF}

interface

uses
  // mORMot first — RawUtf8 types and conversions.
  mormot.core.base,
  mormot.core.unicode,
  mormot.net.http,
  mormot.net.server,
  // RTL last so SysUtils.{Pos, Copy, Trim, LowerCase, Delete, TrimLeft} (which
  // all take/return `string`) shadow the mORMot RawUtf8 overloads of the same
  // names. Otherwise every Pos/Copy/Trim call in this unit triggers two W1057
  // implicit string casts (string → UTF8String → string).
{$IF DEFINED(FPC)}
  Classes,
  SysUtils,
{$ELSE}
  System.Classes,
  System.SysUtils,
{$ENDIF}
  Horse.Provider.RawInterfaces;

type
  TMormotRawRequest = class(TInterfacedObject, IHorseRawRequest)
  private
    FCtxt:          THttpServerRequestAbstract;
    FContentCache:  string;
    FContentCached: Boolean;
    FPathInfo:      string;
    FQueryString:   string;
    FPathParsed:    Boolean;
    procedure ParsePath;
  public
    constructor Create(const ACtxt: THttpServerRequestAbstract);

    { IHorseRawRequest }
    function  GetMethod: string;
    function  GetProtocolVersion: string;
    function  GetURL: string;
    function  GetPathInfo: string;
    function  GetQueryString: string;
    function  GetHost: string;
    function  GetRemoteAddr: string;
    function  GetServerPort: Integer;
    function  GetContentType: string;
    function  GetContent: string;
{$IF DEFINED(FPC)}
    function  GetContentLength: Integer;
{$ELSEIF CompilerVersion >= 32.0}
    function  GetContentLength: Int64;
{$ELSE}
    function  GetContentLength: Integer;
{$IFEND}
    function  GetFieldByName(const AName: string): string;
    procedure PopulateQueryFields(ADest: TStrings);
    procedure PopulateContentFields(ADest: TStrings);
    procedure PopulateCookieFields(ADest: TStrings);
    function  ReadBody(var Buffer; Count: Integer): Integer;
  end;

implementation

constructor TMormotRawRequest.Create(const ACtxt: THttpServerRequestAbstract);
begin
  inherited Create;
  FCtxt          := ACtxt;
  FContentCached := False;
  FPathParsed    := False;
end;

procedure TMormotRawRequest.ParsePath;
var
  S: string;
  QPos: Integer;
begin
  if FPathParsed then Exit;
  S := Utf8ToString(FCtxt.Url);
  QPos := Pos('?', S);
  if QPos > 0 then
  begin
    FPathInfo    := Copy(S, 1, QPos - 1);
    FQueryString := Copy(S, QPos + 1, MaxInt);
  end
  else
  begin
    FPathInfo    := S;
    FQueryString := '';
  end;
  FPathParsed := True;
end;

function TMormotRawRequest.GetMethod: string;
begin
  Result := Utf8ToString(FCtxt.Method);
end;

function TMormotRawRequest.GetProtocolVersion: string;
begin
  Result := 'HTTP/1.1';
end;

function TMormotRawRequest.GetURL: string;
begin
  Result := Utf8ToString(FCtxt.Url);
end;

function TMormotRawRequest.GetPathInfo: string;
begin
  ParsePath;
  Result := FPathInfo;
end;

function TMormotRawRequest.GetQueryString: string;
begin
  ParsePath;
  Result := FQueryString;
end;

function TMormotRawRequest.GetHost: string;
begin
  Result := Utf8ToString(FCtxt.Host);
end;

function TMormotRawRequest.GetRemoteAddr: string;
begin
  Result := Utf8ToString(FCtxt.RemoteIP);
end;

function TMormotRawRequest.GetServerPort: Integer;
begin
  Result := 0;
end;

function TMormotRawRequest.GetContentType: string;
begin
  Result := Utf8ToString(FCtxt.InContentType);
end;

function TMormotRawRequest.GetContent: string;
begin
  if FContentCached then Exit(FContentCache);
  FContentCache  := Utf8ToString(RawUtf8(FCtxt.InContent));
  FContentCached := True;
  Result := FContentCache;
end;

{$IF DEFINED(FPC)}
function TMormotRawRequest.GetContentLength: Integer;
{$ELSEIF CompilerVersion >= 32.0}
function TMormotRawRequest.GetContentLength: Int64;
{$ELSE}
function TMormotRawRequest.GetContentLength: Integer;
{$IFEND}
begin
  Result := Length(FCtxt.InContent);
end;

function TMormotRawRequest.GetFieldByName(const AName: string): string;
var
  LHeaders: string;
  LSearch:  string;
  LPos, LEnd, LValStart: Integer;
begin
  Result := '';
  LHeaders := Utf8ToString(FCtxt.InHeaders);
  LSearch  := LowerCase(AName) + ':';
  LPos := Pos(LSearch, LowerCase(LHeaders));
  if LPos > 0 then
  begin
    LValStart := LPos + Length(LSearch) + 1;
    if LValStart > Length(LHeaders) then
      Exit;
    LEnd := Pos(#13, Copy(LHeaders, LValStart, MaxInt));
    if LEnd = 0 then
      LEnd := Length(LHeaders) - LValStart + 2;
    Result := Trim(Copy(LHeaders, LValStart, LEnd - 1));
  end;
end;

procedure TMormotRawRequest.PopulateQueryFields(ADest: TStrings);
var
  S, Pair, Key, Val: string;
  AmpPos, EqPos: Integer;
begin
  S := GetQueryString;
  while S <> '' do
  begin
    AmpPos := Pos('&', S);
    if AmpPos > 0 then
    begin
      Pair := Copy(S, 1, AmpPos - 1);
      Delete(S, 1, AmpPos);
    end
    else
    begin
      Pair := S;
      S := '';
    end;
    EqPos := Pos('=', Pair);
    if EqPos > 0 then
    begin
      Key := Copy(Pair, 1, EqPos - 1);
      Val := Copy(Pair, EqPos + 1, MaxInt);
    end
    else
    begin
      Key := Pair;
      Val := '';
    end;
    if Key <> '' then
      ADest.Add(Key + '=' + Val);
  end;
end;

procedure TMormotRawRequest.PopulateContentFields(ADest: TStrings);
var
  S, Pair: string;
  AmpPos: Integer;
begin
  if Pos('application/x-www-form-urlencoded', LowerCase(GetContentType)) > 0 then
  begin
    S := GetContent;
    while S <> '' do
    begin
      AmpPos := Pos('&', S);
      if AmpPos > 0 then
      begin
        Pair := Copy(S, 1, AmpPos - 1);
        Delete(S, 1, AmpPos);
      end
      else
      begin
        Pair := S;
        S := '';
      end;
      ADest.Add(Pair);
    end;
  end;
end;

procedure TMormotRawRequest.PopulateCookieFields(ADest: TStrings);
var
  S, Pair: string;
  SemiPos, EqPos: Integer;
  CookieName, CookieVal: string;
begin
  S := Trim(GetFieldByName('Cookie'));
  while S <> '' do
  begin
    SemiPos := Pos(';', S);
    if SemiPos > 0 then
    begin
      Pair := Trim(Copy(S, 1, SemiPos - 1));
      Delete(S, 1, SemiPos);
      S := TrimLeft(S);
    end
    else
    begin
      Pair := Trim(S);
      S := '';
    end;
    if Pair <> '' then
    begin
      EqPos := Pos('=', Pair);
      if EqPos > 0 then
      begin
        CookieName := Trim(Copy(Pair, 1, EqPos - 1));
        CookieVal  := Trim(Copy(Pair, EqPos + 1, MaxInt));
      end
      else
      begin
        CookieName := Pair;
        CookieVal  := '';
      end;
      ADest.Add(CookieName + '=' + CookieVal);
    end;
  end;
end;

function TMormotRawRequest.ReadBody(var Buffer; Count: Integer): Integer;
var
  LLen: Integer;
begin
  LLen := Length(FCtxt.InContent);
  if LLen = 0 then Exit(0);
  if Count > LLen then
    Count := LLen;
  Move(FCtxt.InContent[1], Buffer, Count);
  Result := Count;
end;

end.
