unit Horse.Provider.Mormot.Request;

(*
  Horse mORMot Provider — Request Bridge
  ---------------------------------------
  Bridges THttpServerRequestAbstract (mORMot2) to THorseRequest.

  ── Prerequisite: Horse fork patches ───────────────────────────────────────
  PATCH-REQ-3 (Horse.Request.pas)
    procedure THorseRequest.Populate(AMethod, AMethodType, APath,
                                     AContentType, ARemoteAddr)
    Injects per-request values into private shadow fields, bypassing
    FWebRequest (nil on this path).

  PATCH-REQ-8 (Horse.Request.pas)
    procedure THorseRequest.SetCSRawWebRequest(AWReq: TWebRequest)
    Stores a TCrossSocket/TMormot WebRequest adapter so that existing
    middleware using Req.RawWebRequest.* (e.g. Horse.CORS) works unchanged.

  PATCH-REQ-9 (Horse.Request.pas)
    procedure THorseRequest.SetBodyString(const AValue: string)
    Caches the decoded body as FBodyString so Req.Body (string) is O(1).

  ── Security checks (same contract as CrossSocket provider) ────────────────
  [SEC-12] HTTP Request Smuggling — reject if CL + TE both present.
  [SEC-13] Header count and name/value size limits.
  [SEC-14] URL length limit: 8 KB.
  [SEC-15] HTTP method allowlist (GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS).
  [SEC-16] Body size limit — passed in from THorseMormotConfig.MaxBodyBytes.
           Returns rvPayloadTooLarge (→ 413) when exceeded. Checked here
           because mORMot has already buffered the full body in InContent
           by the time Validate is called.
  [SEC-17] Host header — missing or non-printable-ASCII → 400.
  [SEC-18] Query string key/value size limits: 2 KB each.

  ── mORMot-specific body notes ─────────────────────────────────────────────
  mORMot buffers the request body in THttpServerRequestAbstract.InContent
  (RawByteString) — it is owned entirely by the mORMot context.  We decode
  it to a Pascal string once here via SetBodyString; THorseRequest.FBody is
  left nil (no TStream on this path).

  Dual-compilation: Delphi and FPC.
*)

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  // ── mORMot first ────────────────────────────────────────────────────────
  // RawUtf8 / RawByteString types and the multipart decoder.
  mormot.core.base,
  mormot.core.unicode,
  mormot.core.buffers,   // MultiPartFormDataDecode for multipart/form-data
  mormot.net.http,
  mormot.net.server,
  // ── RTL last ────────────────────────────────────────────────────────────
  // SysUtils LAST so its `string`-taking overloads of Pos/Copy/Trim/LowerCase
  // resolve ahead of mORMot's RawUtf8 overloads (Delphi resolves identifiers
  // in reverse uses-clause order — later wins). Avoids W1057 implicit string
  // casts on every `Pos(s, LowerCase(s))` line.
{$IF DEFINED(FPC)}
  Classes,
  SysUtils,
{$ELSE}
  System.Classes,
  System.SysUtils,
{$ENDIF}
  Horse.Request,
  Horse.Commons,
  Horse.Provider.Mormot.WebRequestAdapter
{$IF NOT DEFINED(FPC)}
  , Web.HTTPApp
{$ENDIF}
  ;

const
  // [SEC-13]
  MAX_HEADER_COUNT     = 100;
  MAX_HEADER_NAME_LEN  = 256;
  MAX_HEADER_VALUE_LEN = 8192;
  // [SEC-14]
  MAX_URL_LEN          = 8192;
  // [SEC-18]
  MAX_QUERY_KEY_LEN    = 2048;
  MAX_QUERY_VALUE_LEN  = 2048;

type
  TRequestValidationResult = (
    rvOK,
    rvBadRequest,        // malformed URL, Host, smuggling, or excess headers
    rvMethodNotAllowed,  // verb not in allowlist [SEC-15]
    rvPayloadTooLarge    // body exceeds MaxBodyBytes [SEC-16]
  );

  TMormotRequestBridge = class
  public
    class function Validate(
      const ACtxt:         THttpServerRequestAbstract;
      out   ARejectReason: string;
            AMaxBodyBytes: Int64
    ): TRequestValidationResult;

    class procedure Populate(
      const ACtxt:           THttpServerRequestAbstract;
      const AHorseReq:       THorseRequest;
            AMaxHeaderCount: Integer
    );

  private
    class function MapMethodType(const AMethod: RawUtf8): TMethodType;
    class procedure PopulateMultipartFields(
      const ACtxt:     THttpServerRequestAbstract;
      const AHorseReq: THorseRequest);
  end;

implementation

const
  ALLOWED_METHODS: array[0..6] of string = (
    'GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS'
  );

{ TMormotRequestBridge }

// ── [SEC-15][SEC-17][SEC-12][SEC-16] Validation — called before pool acquire ──
class function TMormotRequestBridge.Validate(
  const ACtxt:         THttpServerRequestAbstract;
  out   ARejectReason: string;
        AMaxBodyBytes: Int64
): TRequestValidationResult;
var
  LMethod:  string;
  LUrl:     string;
  LHost:    string;
  LHeaders: string;
  HasCL, HasTE: Boolean;
  LTePos, LTeEnd: Integer;
  LTeValue: string;
  I: Integer;
  C: Char;
begin
  ARejectReason := '';

  // ── [SEC-15] Method allowlist ─────────────────────────────────────────────
  LMethod := Utf8ToString(ACtxt.Method);
  Result  := rvMethodNotAllowed;
  for I := 0 to High(ALLOWED_METHODS) do
    if SameText(LMethod, ALLOWED_METHODS[I]) then
    begin
      Result := rvOK;
      Break;
    end;
  if Result <> rvOK then
  begin
    ARejectReason := 'Method Not Allowed: ' + LMethod;
    Exit;
  end;

  // ── [SEC-14] URL length guard ─────────────────────────────────────────────
  LUrl := Utf8ToString(ACtxt.Url);
  if Length(LUrl) > MAX_URL_LEN then
  begin
    ARejectReason := 'URI Too Long';
    Exit(rvBadRequest);
  end;

  // ── [SEC-17] Host validation ──────────────────────────────────────────────
  LHost := Utf8ToString(ACtxt.Host);
  if LHost = '' then
  begin
    ARejectReason := 'Missing Host header';
    Exit(rvBadRequest);
  end;
  for I := 1 to Length(LHost) do
  begin
    C := LHost[I];
    if (Ord(C) < 32) or (Ord(C) > 126) then
    begin
      ARejectReason := 'Invalid Host header';
      Exit(rvBadRequest);
    end;
  end;

  // ── [SEC-12] Request smuggling — CL + TE both present ────────────────────
  LHeaders := Utf8ToString(ACtxt.InHeaders);
  HasCL    := Pos('content-length:', LowerCase(LHeaders)) > 0;

  LTePos := Pos('transfer-encoding:', LowerCase(LHeaders));
  HasTE  := LTePos > 0;
  if HasTE then
  begin
    LTePos := LTePos + Length('transfer-encoding:');
    while (LTePos <= Length(LHeaders)) and (LHeaders[LTePos] = ' ') do
      Inc(LTePos);
    LTeEnd := Pos(#13, Copy(LHeaders, LTePos, MaxInt));
    if LTeEnd = 0 then
      LTeEnd := Length(LHeaders) - LTePos + 2;
    LTeValue := Trim(LowerCase(Copy(LHeaders, LTePos, LTeEnd - 1)));
  end
  else
    LTeValue := '';

  if HasCL and HasTE then
  begin
    ARejectReason := 'Ambiguous framing: both Content-Length and Transfer-Encoding present';
    Exit(rvBadRequest);
  end;

  if HasTE and (LTeValue <> 'chunked') and (LTeValue <> 'identity') then
  begin
    ARejectReason := 'Unsupported Transfer-Encoding: ' + LTeValue;
    Exit(rvBadRequest);
  end;

  // ── [SEC-16] Body size guard ──────────────────────────────────────────────
  // mORMot has already buffered the full body before Validate is called.
  // A zero/negative limit means unlimited (disabled in config).
  if (AMaxBodyBytes > 0) and (Int64(Length(ACtxt.InContent)) > AMaxBodyBytes) then
  begin
    ARejectReason := 'Payload Too Large';
    Exit(rvPayloadTooLarge);
  end;

  Result := rvOK;
end;

// ── Populate — full request population after validation ──────────────────────
class procedure TMormotRequestBridge.Populate(
  const ACtxt:           THttpServerRequestAbstract;
  const AHorseReq:       THorseRequest;
        AMaxHeaderCount: Integer
);
var
  LUrl:      string;
  LPathInfo: string;
  QPos:      Integer;
  LHeaders:  string;
  LPtr, LEnd, LColonPos: Integer;
  LLine, LName, LValue: string;
  LCount:    Integer;
  LQuery:    string;
  LPos, LNextAmp, LEqPos: Integer;
  LPair, LKey, LVal: string;
  LCookiePos: Integer;
  LCookieStr, LTemp: string;
  LSemiPos: Integer;
  LCookieKey, LCookieVal: string;
  LContentType: string;
begin
  if not Assigned(AHorseReq) then
    Exit;

  // ── Extract decoded path (without query string) ───────────────────────────
  LUrl := Utf8ToString(ACtxt.Url);
  QPos := Pos('?', LUrl);
  if QPos > 0 then
    LPathInfo := Copy(LUrl, 1, QPos - 1)
  else
    LPathInfo := LUrl;
  if (LPathInfo = '') or (LPathInfo[1] <> '/') then
    LPathInfo := '/' + LPathInfo;

  // ── PATCH-REQ-3: inject shadow fields ────────────────────────────────────
  // Sets FCSMethod, FCSMethodType, FCSPathInfo, FCSContentType, FCSRemoteAddr.
  // Also initialises FHeaders as an empty THorseCoreParam ready to populate.
  AHorseReq.Populate(
    Utf8ToString(ACtxt.Method),
    MapMethodType(ACtxt.Method),
    LPathInfo,
    Utf8ToString(ACtxt.InContentType),
    Utf8ToString(ACtxt.RemoteIP)
  );

  // ── [SEC-13] Header parsing with count + size guards ─────────────────────
  LHeaders := Utf8ToString(ACtxt.InHeaders);
  LPtr     := 1;
  LCount   := 0;
  while LPtr <= Length(LHeaders) do
  begin
    LEnd := Pos(#13, Copy(LHeaders, LPtr, MaxInt));
    if LEnd = 0 then
      LEnd := Length(LHeaders) - LPtr + 2;
    LLine := Copy(LHeaders, LPtr, LEnd - 1);
    LPtr  := LPtr + LEnd;
    if (LPtr <= Length(LHeaders)) and (LHeaders[LPtr] = #10) then
      Inc(LPtr);
    if LLine = '' then Continue;

    Inc(LCount);
    if LCount > AMaxHeaderCount then Break;   // [SEC-13-a]

    LColonPos := Pos(':', LLine);
    if LColonPos = 0 then Continue;
    LName  := Trim(Copy(LLine, 1, LColonPos - 1));
    LValue := Trim(Copy(LLine, LColonPos + 1, MaxInt));
    if LName = '' then Continue;                                        // [SEC-13-e]
    if Length(LName) > MAX_HEADER_NAME_LEN then Continue;              // [SEC-13-b]
    if Length(LValue) > MAX_HEADER_VALUE_LEN then Continue;            // [SEC-13-c]
    if (Pos(#13, LName) > 0) or (Pos(#10, LName) > 0) then Continue; // [SEC-13-d]

    AHorseReq.Headers.Dictionary.AddOrSetValue(LName, LValue);
  end;

  // ── Query params ──────────────────────────────────────────────────────────
  QPos := Pos('?', LUrl);
  if QPos > 0 then
  begin
    LQuery := Copy(LUrl, QPos + 1, MaxInt);
    LPos   := 1;
    while LPos <= Length(LQuery) do
    begin
      LNextAmp := Pos('&', Copy(LQuery, LPos, MaxInt));
      if LNextAmp = 0 then
        LNextAmp := Length(LQuery) - LPos + 2;
      LPair := Copy(LQuery, LPos, LNextAmp - 1);
      LPos  := LPos + LNextAmp;
      LEqPos := Pos('=', LPair);
      if LEqPos > 0 then
      begin
        LKey := Copy(LPair, 1, LEqPos - 1);
        LVal := Copy(LPair, LEqPos + 1, MaxInt);
      end
      else
      begin
        LKey := LPair;
        LVal := '';
      end;
      if LKey = '' then Continue;
      if (Length(LKey) > MAX_QUERY_KEY_LEN) or         // [SEC-18]
         (Length(LVal) > MAX_QUERY_VALUE_LEN) then Continue;
      AHorseReq.Query.Dictionary.AddOrSetValue(LKey, LVal);
    end;
  end;

  // ── Cookie parsing ────────────────────────────────────────────────────────
  LCookiePos := Pos('cookie:', LowerCase(LHeaders));
  if LCookiePos > 0 then
  begin
    LTemp := Copy(LHeaders, LCookiePos + Length('cookie:'), MaxInt);
    while (Length(LTemp) > 0) and (LTemp[1] = ' ') do
      Delete(LTemp, 1, 1);
    LEnd := Pos(#13, LTemp);
    if LEnd = 0 then
      LEnd := Length(LTemp);
    LCookieStr := Copy(LTemp, 1, LEnd - 1);
    LPos := 1;
    while LPos <= Length(LCookieStr) do
    begin
      LSemiPos := Pos(';', Copy(LCookieStr, LPos, MaxInt));
      if LSemiPos = 0 then
        LSemiPos := Length(LCookieStr) - LPos + 2;
      LPair := Trim(Copy(LCookieStr, LPos, LSemiPos - 1));
      LPos  := LPos + LSemiPos;
      if LPair = '' then Continue;
      LEqPos := Pos('=', LPair);
      if LEqPos > 0 then
      begin
        LCookieKey := Trim(Copy(LPair, 1, LEqPos - 1));
        LCookieVal := Trim(Copy(LPair, LEqPos + 1, MaxInt));
      end
      else
      begin
        LCookieKey := LPair;
        LCookieVal := '';
      end;
      if LCookieKey <> '' then
        AHorseReq.Cookie.Dictionary.AddOrSetValue(LCookieKey, LCookieVal);
    end;
  end;

  // ── Content fields (application/x-www-form-urlencoded) ───────────────────
  LContentType := LowerCase(Utf8ToString(ACtxt.InContentType));
  if Pos('application/x-www-form-urlencoded', LContentType) > 0 then
  begin
    if Length(ACtxt.InContent) > 0 then
    begin
      LQuery := Utf8ToString(RawUtf8(ACtxt.InContent));
      LPos   := 1;
      while LPos <= Length(LQuery) do
      begin
        LNextAmp := Pos('&', Copy(LQuery, LPos, MaxInt));
        if LNextAmp = 0 then
          LNextAmp := Length(LQuery) - LPos + 2;
        LPair := Copy(LQuery, LPos, LNextAmp - 1);
        LPos  := LPos + LNextAmp;
        if LPair <> '' then
          AHorseReq.ContentFields.Dictionary.AddOrSetValue(LPair, '');
      end;
    end;
  end
  // ── Content fields (multipart/form-data) ──────────────────────────────────
  // Uses mORMot's MultiPartFormDataDecode (mormot.core.buffers).  Each part's
  // Name becomes a ContentFields entry; for file parts the value is the raw
  // bytes so Req.ContentFields['file'] returns the upload content the same
  // way the Indy / CrossSocket providers expose it.  The filename is exposed
  // as a sibling entry "<name>_filename" so handlers can read both.
  else if Pos('multipart/form-data', LContentType) > 0 then
  begin
    if Length(ACtxt.InContent) > 0 then
      PopulateMultipartFields(ACtxt, AHorseReq);
  end;

  // ── [PATCH-REQ-9] Body string — decode once, cached for all Req.Body calls
  if Length(ACtxt.InContent) > 0 then
    AHorseReq.SetBodyString(Utf8ToString(RawUtf8(ACtxt.InContent)));

  // ── [PATCH-REQ-8] RawWebRequest adapter ──────────────────────────────────
  // Middleware using Req.RawWebRequest.Method / .Host / .GetFieldByName(...)
  // (e.g. Horse.CORS) receives a fully populated TWebRequest subclass backed
  // by ACtxt instead of a nil pointer.
  AHorseReq.SetCSRawWebRequest(TMormotWebRequest.Create(ACtxt));
end;

// ── PopulateMultipartFields ──────────────────────────────────────────────────
// Decodes a multipart/form-data body via mORMot's MultiPartFormDataDecode and
// populates AHorseReq.ContentFields with one entry per part:
//   ContentFields[Name]                  → text content (or raw bytes for files)
//   ContentFields[Name + '_filename']    → original filename, when present
//   ContentFields[Name + '_contenttype'] → declared Content-Type, when present
//
// Mirrors the surface that the Indy and CrossSocket providers expose so route
// handlers like `Req.ContentFields['file']` and `Req.ContentFields['fieldname']`
// work identically across all three transports.
class procedure TMormotRequestBridge.PopulateMultipartFields(
  const ACtxt:     THttpServerRequestAbstract;
  const AHorseReq: THorseRequest);
var
  LParts:  TMultiPartDynArray;
  I:       Integer;
  LName:   string;
  LValue:  string;
  LStream: TMemoryStream;
begin
  if not MultiPartFormDataDecode(
       ACtxt.InContentType, RawUtf8(ACtxt.InContent), LParts) then
    Exit;

  for I := 0 to High(LParts) do
  begin
    LName := Utf8ToString(LParts[I].Name);
    if LName = '' then Continue;

    if LParts[I].FileName <> '' then
    begin
      // File-part: hand the bytes to Horse as a TStream via AddStream so
      // Req.ContentFields.Field(LName).AsStream returns them intact. The
      // string-dictionary path would route through Utf8ToString, which
      // corrupts non-UTF-8 binary uploads.
      //
      // [FOLLOW-UP-MEM-1] Ownership gap: Horse.Core.Param's FFiles is a plain
      // TDictionary<string, TStream> with no doOwnsValues — destruction frees
      // the dict but not the stream values. CrossSocket sidesteps this because
      // its multipart streams are owned by THttpMultiPartFormData (freed with
      // the ICrossHttpRequest). mORMot's MultiPartFormDataDecode produces
      // inline RawByteString content with no owning object, so we synthesise
      // a TMemoryStream here and accept that it leaks until the pool is torn
      // down. Proper fix: extend the pool's Reset cycle to track and free
      // bridge-allocated streams, or push a Horse upstream patch making FFiles
      // a TObjectDictionary([doOwnsValues]).
      LStream := TMemoryStream.Create;
      if Length(LParts[I].Content) > 0 then
        LStream.WriteBuffer(Pointer(LParts[I].Content)^, Length(LParts[I].Content));
      LStream.Position := 0;
      AHorseReq.ContentFields.AddStream(LName, LStream);

      // Sibling text entries so Req.ContentFields['file_filename'] /
      // ['file_contenttype'] also resolve — mirrors the existing pattern that
      // pre-dated the stream change.
      AHorseReq.ContentFields.Dictionary.AddOrSetValue(
        LName + '_filename', Utf8ToString(LParts[I].FileName));
      if LParts[I].ContentType <> '' then
        AHorseReq.ContentFields.Dictionary.AddOrSetValue(
          LName + '_contenttype', Utf8ToString(LParts[I].ContentType));
    end
    else
    begin
      // Plain form field — string-dictionary path, UTF-8 conversion is safe
      // for text/* parts.
      LValue := Utf8ToString(RawUtf8(LParts[I].Content));
      AHorseReq.ContentFields.Dictionary.AddOrSetValue(LName, LValue);

      // A part without a FileName can still carry an explicit Content-Type
      // (e.g. 'application/json' for a JSON form field). Surface it so
      // handlers can read Req.ContentFields[LName + '_contenttype'] uniformly.
      if LParts[I].ContentType <> '' then
        AHorseReq.ContentFields.Dictionary.AddOrSetValue(
          LName + '_contenttype', Utf8ToString(LParts[I].ContentType));
    end;
  end;
end;

// ── MapMethodType ─────────────────────────────────────────────────────────────
class function TMormotRequestBridge.MapMethodType(
  const AMethod: RawUtf8
): TMethodType;
var
  S: string;
begin
  S := Utf8ToString(AMethod);
  if      SameText(S, 'GET')    then Result := mtGet
  else if SameText(S, 'POST')   then Result := mtPost
  else if SameText(S, 'PUT')    then Result := mtPut
  else if SameText(S, 'DELETE') then Result := mtDelete
  else if SameText(S, 'PATCH')  then Result := mtPatch
  else if SameText(S, 'HEAD')   then Result := mtHead
  // OPTIONS and any unrecognised method → mtAny (Horse wildcard routes)
  else                               Result := mtAny;
end;

end.
