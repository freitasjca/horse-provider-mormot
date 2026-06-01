unit Horse.Provider.Mormot.Response;

(*
  Horse mORMot Provider — Response Bridge
  ----------------------------------------
  Flushes a fully-populated THorseResponse to mORMot's
  THttpServerRequestAbstract output fields and returns the HTTP status code.

  ── Prerequisite: Horse fork patches ───────────────────────────────────────
  PATCH-RES-4 (Horse.Response.pas)
    property BodyText:      string  read FCSBody
    property ContentStream: TStream read FCSContentStream
    property CSContentType: string  read FCSContentType
    function  Status: Integer       (nil-guarded getter — returns FCSStatusCode
                                     when FWebResponse is nil)

  PATCH-RES-1/3 (Horse.Response.pas)
    property CustomHeaders: TDictionary<string,string>  (Delphi)
                          / TStringList                  (FPC)

  PATCH-RES-6 (Horse.Response.pas)
    property RawWebResponse: TWebResponse  (returns FCSRawWebResponse when
                                            FWebResponse is nil)

  ── mORMot output fields written here ──────────────────────────────────────
    ACtxt.OutContent        := <body as RawByteString>
    ACtxt.OutContentType    := <MIME type as RawUtf8>
    ACtxt.OutCustomHeaders  := <CRLF-separated header lines as RawUtf8>
  Return value: HTTP status code as cardinal.

  ── Security ────────────────────────────────────────────────────────────────
  [SEC-19] CRLF stripping on all response header values.
  [SEC-20] Hop-by-hop header filtering.
  [SEC-21] Content-Type applied from shadow field; falls back to COMPAT-1.
  [SEC-22] X-Content-Type-Options: nosniff.
  [SEC-23] X-Frame-Options, Referrer-Policy, Cache-Control.
  [SEC-5]  Server: banner from config.

  ── COMPAT-1 ────────────────────────────────────────────────────────────────
  Middleware that writes via Res.RawWebResponse.Content / .ContentType or
  Res.RawWebResponse.SetCustomHeader (e.g. horse-jhonson, Horse.CORS) has
  its output picked up via AHorseRes.RawWebResponse when the shadow fields
  are empty.

  Dual-compilation: Delphi and FPC.
*)

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  // mORMot first — RawUtf8 types and conversions.
  mormot.core.base,
  mormot.core.unicode,
  mormot.net.http,
  mormot.net.server,
  // RTL last so SysUtils.{Pos, Copy, Trim, LowerCase, StringReplace} (which
  // take/return `string`) shadow the mORMot RawUtf8 overloads. Otherwise
  // every header-sanitising call triggers W1057 implicit string casts.
{$IF DEFINED(FPC)}
  Classes,
  SysUtils,
{$ELSE}
  System.Classes,
  System.SysUtils,
  System.Generics.Collections,
{$ENDIF}
  Horse.Response
{$IF NOT DEFINED(FPC)}
  , Web.HTTPApp
{$ENDIF}
  ;

type
  TMormotResponseBridge = class
  public
    /// Flush AHorseRes to ACtxt output fields.
    /// AServerBanner: value for the Server: header; '' → 'unknown'.
    /// Returns the HTTP status code as cardinal (mORMot OnRequest return value).
    class function Flush(
            AHorseRes:       THorseResponse;
      const ACtxt:           THttpServerRequestAbstract;
      const AServerBanner:   string
    ): cardinal;

  private
    class function  SanitiseHeaderValue(const AValue: string): string;
    class function  IsHopByHopHeader(const AName: string): Boolean;
    class function  BuildHeaders(
                            AHorseRes:     THorseResponse;
                      const AServerBanner: string): string;
    class function  WriteBody(
                            AHorseRes:   THorseResponse;
                      const ACtxt:       THttpServerRequestAbstract;
                            AStatus:     Integer): RawByteString;
  end;

implementation

// ── [SEC-20] Hop-by-hop headers — managed by mORMot, not by the app ──────────
const
  HOP_BY_HOP: array[0..8] of string = (
    'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
    'te', 'trailers', 'transfer-encoding', 'upgrade', 'server'
  );

{ TMormotResponseBridge }

class function TMormotResponseBridge.Flush(
        AHorseRes:       THorseResponse;
  const ACtxt:           THttpServerRequestAbstract;
  const AServerBanner:   string
): cardinal;
var
  LStatus: Integer;
  CT:      string;
  LRaw:    {$IF DEFINED(FPC)}TResponse{$ELSE}TWebResponse{$ENDIF};
  LBody:   RawByteString;
  LHdrs:   string;
begin
  // Status — PATCH-RES-4 nil-guarded getter returns FCSStatusCode.
  // Default to 200 when handler never called Res.Status (common for HEAD /
  // empty-Res.Send routes). Returning cardinal(0) from OnRequest makes
  // mORMot's THttpServer drop the connection without sending a response →
  // the client sees status 0 / connection-closed.
  LStatus := AHorseRes.Status;
  if LStatus = 0 then
    LStatus := 200;

  // Set the canonical mORMot field too. THttpServer reads fRespStatus first
  // for HTTP/1.1 line generation; relying only on the cardinal return value
  // works for 200/201/etc. but is fragile for 204 No Content and HEAD where
  // mORMot needs to emit the status line without a body.
  ACtxt.RespStatus := LStatus;
  Result := cardinal(LStatus);

  // Build headers, then **trim the trailing CRLF**. mORMot's documented
  // convention for OutCustomHeaders is "CRLF between lines, never on the
  // last line" — see AppendLine in mormot.core.text.pas line 9530, which
  // skips adding the separator if the text already ends with #10. A
  // trailing CRLF here causes any later mORMot internal AppendLine call
  // to corrupt the headers by concatenating onto the last header line
  // instead of starting a new one.
  LHdrs := BuildHeaders(AHorseRes, AServerBanner);
  while (LHdrs <> '') and
        ((LHdrs[Length(LHdrs)] = #10) or
         (LHdrs[Length(LHdrs)] = #13)) do
    SetLength(LHdrs, Length(LHdrs) - 1);

  // [SEC-23][SEC-22][SEC-5] Security + app headers
  ACtxt.OutCustomHeaders := StringToUtf8(LHdrs);

  // [SEC-21] Content-Type from shadow field first
  CT := AHorseRes.CSContentType;
  // [COMPAT-1] Fall back to RawWebResponse.ContentType when shadow field empty
  if CT = '' then
  begin
    LRaw := AHorseRes.RawWebResponse;
    if Assigned(LRaw) then
      CT := LRaw.ContentType;
  end;
  if CT <> '' then
    ACtxt.OutContentType := StringToUtf8(CT);

  // Body
  LBody := WriteBody(AHorseRes, ACtxt, LStatus);
  ACtxt.OutContent := LBody;
end;

// ── [SEC-19] ─────────────────────────────────────────────────────────────────
class function TMormotResponseBridge.SanitiseHeaderValue(
  const AValue: string
): string;
begin
  Result := StringReplace(AValue, #13, '', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '', [rfReplaceAll]);
  Result := StringReplace(Result, #0,  '', [rfReplaceAll]);
end;

// ── [SEC-20] ─────────────────────────────────────────────────────────────────
class function TMormotResponseBridge.IsHopByHopHeader(
  const AName: string
): Boolean;
var
  Lower: string;
  H:     string;
begin
  Lower := LowerCase(AName);
  for H in HOP_BY_HOP do
    if Lower = H then Exit(True);
  Result := False;
end;

// ── Build OutCustomHeaders string ─────────────────────────────────────────────
class function TMormotResponseBridge.BuildHeaders(
        AHorseRes:     THorseResponse;
  const AServerBanner: string
): string;

  procedure EmitHeader(var AOut: string; const AName, AValue: string);
  var
    SafeVal: string;
  begin
    if IsHopByHopHeader(AName) then Exit;            // [SEC-20]
    if (Pos(#13, AName) > 0) or (Pos(#10, AName) > 0) then Exit; // [SEC-19]
    SafeVal := SanitiseHeaderValue(AValue);          // [SEC-19]
    AOut := AOut + AName + ': ' + SafeVal + #13#10;
  end;

var
  LHeaders:  string;
  LRaw:      {$IF DEFINED(FPC)}TResponse{$ELSE}TWebResponse{$ENDIF};
  I:         Integer;
  LName, LVal: string;
{$IF NOT DEFINED(FPC)}
  Pair: TPair<string, string>;
{$ENDIF}
begin
  // [SEC-22][SEC-23][SEC-5] Security defaults
  LHeaders :=
    'X-Content-Type-Options: nosniff'#13#10 +
    'X-Frame-Options: DENY'#13#10 +
    'Referrer-Policy: strict-origin-when-cross-origin'#13#10 +
    'Cache-Control: no-store'#13#10;
  if AServerBanner <> '' then
    LHeaders := LHeaders + 'Server: ' + AServerBanner + #13#10
  else
    LHeaders := LHeaders + 'Server: unknown'#13#10;

  // App-set headers via Horse API (Res.AddHeader) — PATCH-RES-1/3
  if Assigned(AHorseRes.CustomHeaders) then
  begin
{$IF DEFINED(FPC)}
    for I := 0 to AHorseRes.CustomHeaders.Count - 1 do
    begin
      LName := AHorseRes.CustomHeaders.Names[I];
      LVal  := AHorseRes.CustomHeaders.ValueFromIndex[I];
      if LName <> '' then
        EmitHeader(LHeaders, LName, LVal);
    end;
{$ELSE}
    for Pair in AHorseRes.CustomHeaders do
      EmitHeader(LHeaders, Pair.Key, Pair.Value);
{$ENDIF}
  end;

  // [COMPAT-1] Headers written via Res.RawWebResponse.SetCustomHeader
  // (e.g. Horse.CORS injects Access-Control-* this way)
  LRaw := AHorseRes.RawWebResponse;
  if Assigned(LRaw) and Assigned(LRaw.CustomHeaders) then
  begin
    for I := 0 to LRaw.CustomHeaders.Count - 1 do
    begin
      LName := LRaw.CustomHeaders.Names[I];
      LVal  := LRaw.CustomHeaders.ValueFromIndex[I];
      if LName <> '' then
        EmitHeader(LHeaders, LName, LVal);
    end;
  end;

  Result := LHeaders;
end;

// ── WriteBody ─────────────────────────────────────────────────────────────────
class function TMormotResponseBridge.WriteBody(
        AHorseRes: THorseResponse;
  const ACtxt:     THttpServerRequestAbstract;
        AStatus:   Integer
): RawByteString;
var
  Stream:   TStream;
  LContent: string;
  LRaw:     {$IF DEFINED(FPC)}TResponse{$ELSE}TWebResponse{$ENDIF};
begin
  // ContentStream — PATCH-RES-4 shadow field
  Stream := AHorseRes.ContentStream;
  if Assigned(Stream) and (Stream.Size > 0) then
  begin
    Stream.Position := 0;
    SetLength(Result, Stream.Size);
    Stream.Read(Result[1], Stream.Size);
    Exit;
  end;

  // BodyText — PATCH-RES-4 shadow field
  if AHorseRes.BodyText <> '' then
  begin
    Result := StringToUtf8(AHorseRes.BodyText);
    Exit;
  end;

  // [COMPAT-1] Middleware (e.g. horse-jhonson) may write via RawWebResponse.Content
  LRaw := AHorseRes.RawWebResponse;
  if Assigned(LRaw) then
  begin
    LContent := LRaw.Content;
    if LContent <> '' then
    begin
      Result := StringToUtf8(LContent);
      Exit;
    end;
  end;

  // Status >= 400 with no body: send status code as minimal text body.
  // Without a body, some HTTP stacks may not deliver the response reliably.
  if AStatus >= 400 then
  begin
    Result := StringToUtf8(IntToStr(AStatus));
    Exit;
  end;

  // Empty body (e.g. 204 No Content)
  Result := '';
end;

end.
