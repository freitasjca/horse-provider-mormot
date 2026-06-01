# Middleware Compatibility — `horse-provider-mormot`

Per-middleware compatibility matrix for the mORMot2 provider. "Compatible" means the middleware source code requires no changes — the provider supplies the required surfaces via the Horse fork patches and the hybrid adapter architecture.

The mORMot provider uses the same `IHorseRawRequest` / `IHorseRawResponse` hybrid adapter pattern as the CrossSocket provider. Any middleware that works on CrossSocket via that pattern also works here.

---

## Compatibility matrix

| Middleware | Compatible | Mechanism | Notes |
|---|---|---|---|
| **horse-cors** | ✅ Yes | PATCH-REQ-8 + PATCH-RES-6 adapters | Calls `Req.RawWebRequest.Method` and `Res.RawWebResponse.SetCustomHeader` — both non-nil via adapters |
| **horse-jhonson** | ✅ Yes | `Res.Send` / `Res.ContentType` shadow fields | Writes via the standard Horse API; COMPAT-1 fallback also picks up `RawWebResponse.Content` on FPC |
| **horse-jwt** | ✅ Yes | `Req.Headers` shadow field | Reads `Authorization` header via nil-guarded `Req.Headers` accessor (PATCH-REQ shadow fields) |
| **horse-logger** | ✅ Yes | `Req.Method`, `Req.PathInfo`, `Res.Status` | All nil-guarded shadow field accessors |
| **horse-basic-authenticator** | ✅ Yes | `Req.Headers['Authorization']` | Same nil-guarded path as JWT |
| **horse-request-guard** | ✅ Yes (redundant) | Horse pipeline level | CrossSocket/mORMot already enforce these checks pre-pipeline (SEC-29). Registering the guard is harmless defence-in-depth. |
| **horse-security-headers** | ✅ Yes (additive) | `Res.AddHeader` shadow field | CrossSocket/mORMot already inject security headers in the response bridge. Registering this middleware adds the headers a second time — HTTP allows duplicates for most security headers. |
| **horse-octet-stream** | ✅ Yes | `Res.Send` / stream shadow fields | Writes via standard Horse API |
| **horse-exception-handler** | ✅ Yes | `Req` / `Res` public API only | No transport dependency |
| **horse-static-files** | ✅ Yes | `Req.PathInfo`, `Res.SendFile` | `Res.SendFile` writes to `FCSContentStream` shadow field; response bridge reads `ContentStream` property |
| **horse-compression** | ⚠️ See note | `Res.Send` + `Req.Headers` | Works at the Horse pipeline level; mORMot does not apply a second gzip pass. If mORMot-native compression is also enabled, responses may be double-compressed. Use one or the other. |
| **horse-fcgi** / **horse-isapi** / **horse-apache** | ❌ No | Architectural incompatibility | Host-managed providers own the socket; self-hosted mORMot transport cannot coexist (PATCH-HORSE-1 guard fires a compile error) |

---

## Detail: Horse.CORS

Horse.CORS reads from `Req.RawWebRequest` and writes to `Res.RawWebResponse`:

```pascal
// horse-cors internal (simplified)
LMethod := Req.RawWebRequest.Method;              // reads from TMormotWebRequest
if SameText(LMethod, 'OPTIONS') then
begin
  Res.RawWebResponse.SetCustomHeader(             // writes to TMormotWebResponse.CustomHeaders
    'Access-Control-Allow-Origin', '*');
  Res.Status(THTTPStatus.NoContent);
  raise EHorseCallbackInterrupted.Create;         // BUG-2: caught explicitly in ExecutePipeline
end;
```

`TMormotWebRequest.Method` delegates to `TMormotRawRequest.GetMethod` → `Utf8ToString(ACtxt.Method)`.

`TMormotWebResponse.SetCustomHeader` is inherited from `TInterfacedWebResponse`, which stores headers in its `CustomHeaders: TStrings` property. The response bridge reads this at flush time via the `COMPAT-1` path:

```pascal
// TMormotResponseBridge.BuildHeaders (Horse.Provider.Mormot.Response)
LRaw := AHorseRes.RawWebResponse;
if Assigned(LRaw) and Assigned(LRaw.CustomHeaders) then
begin
  for I := 0 to LRaw.CustomHeaders.Count - 1 do
    EmitHeader(LHeaders, LRaw.CustomHeaders.Names[I],
                         LRaw.CustomHeaders.ValueFromIndex[I]);
end;
```

This is identical to how CrossSocket handles CORS. No middleware changes required.

---

## Detail: horse-jhonson

horse-jhonson serializes a TObject to JSON and calls `Res.Send(json)` + `Res.ContentType('application/json')`. Both write to the PATCH-RES-4 shadow fields (`FCSBody`, `FCSContentType`) when `FWebResponse` is nil. The response bridge reads `AHorseRes.BodyText` and `AHorseRes.CSContentType`.

On FPC, `TInterfacedWebResponse` inherits `TResponse` and `Res.RawWebResponse.Content` is a real field. horse-jhonson may write to it if it uses `RawWebResponse.Content` directly. The COMPAT-1 fallback in `WriteBody` handles this:

```pascal
// COMPAT-1 — Horse.Provider.Mormot.Response, WriteBody
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
```

Shadow fields take priority over `RawWebResponse.Content` (checked first). If `Res.Send` was called (shadow field populated), COMPAT-1 is bypassed.

---

## Detail: horse-request-guard

`THorseRequestGuard` enforces the same checks as the mORMot provider's pre-pipeline validation:

| Check | mORMot pre-pipeline (SEC-29) | horse-request-guard |
|---|---|---|
| Method allowlist | `TMormotRequestBridge.Validate` — 405 before pool acquire | Pipeline middleware — 405 after acquire |
| Host header | `TMormotRequestBridge.Validate` — 400 before pool acquire | Pipeline middleware — 400 after acquire |
| CL + TE conflict | `TMormotRequestBridge.Validate` — 400 before pool acquire | Pipeline middleware — 400 after acquire |
| URL length | `TMormotRequestBridge.Validate` — 400 before pool acquire | Pipeline middleware — 414 after acquire |
| Header count | `TMormotRequestBridge.Populate` — silently truncates | Pipeline middleware — 431 |
| Body size | `THorseMormotConfig.MaxBodyBytes` (mORMot body limit) | Pipeline middleware — 413 |

Registering horse-request-guard on mORMot is redundant for the pre-pipeline checks but adds pipeline-level enforcement for the body size limit (413 with a structured error) and the header count limit (431). It is **harmless** — the pre-pipeline validation rejects the worst offenders before the guard even runs.

Registration:

```pascal
THorse.Use(THorseRequestGuard.New);    // first in chain
THorse.Use(THorseSecurityHeaders.New); // optional — mORMot already injects these
THorse.Use(CORS);                      // if used
THorse.Get('/ping', ...);
```

---

## Detail: horse-security-headers

The mORMot response bridge already injects the following headers on every response (unconditionally, before app headers):

```
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Referrer-Policy: strict-origin-when-cross-origin
Cache-Control: no-store
Server: <FConfig.ServerBanner or 'unknown'>
```

Registering `THorseSecurityHeaders` adds them again. Most browsers apply the last occurrence of a duplicated header; for idempotent security headers this is harmless. If you need custom security header values (e.g. `SAMEORIGIN` instead of `DENY` for `X-Frame-Options`), skip the middleware and set `FConfig.ServerBanner` / modify `BuildHeaders` directly.

---

## Surfaces accessed by middleware

The table below maps each public Horse API surface to the mORMot mechanism that satisfies it.

### THorseRequest surfaces

| Surface | How mORMot satisfies it | Patch |
|---|---|---|
| `Req.Body : string` | `SetBodyString(Utf8ToString(InContent))` — cached, O(1), idempotent | PATCH-REQ-9 |
| `Req.Body<TStream>` | Always nil on mORMot path (body is a RawByteString, not a TStream) | — |
| `Req.Headers['X']` | Parsed from `InHeaders` CRLF block into `FHeaders` dictionary | PATCH-REQ-3 |
| `Req.Params['id']` | Populated by Horse router tree from the matched route pattern | standard |
| `Req.Query['k']` | Parsed from `?key=value` portion of `ACtxt.Url` | PATCH-REQ-3 |
| `Req.Cookie['c']` | Parsed from `Cookie:` header in `InHeaders` | PATCH-REQ-3 |
| `Req.ContentFields['f']` | Parsed from `application/x-www-form-urlencoded` body | PATCH-REQ-3 |
| `Req.PathInfo` | `FCSPathInfo` shadow field (path without query string) | PATCH-REQ-3 |
| `Req.MethodType` | `FCSMethodType` shadow field (mapped from method string) | PATCH-REQ-3 |
| `Req.RawWebRequest` | `TMormotWebRequest` adapter — non-nil always on mORMot path | PATCH-REQ-8 |
| `Req.RawWebRequest.Method` | Delegates to `TMormotRawRequest.GetMethod` | PATCH-REQ-8 |
| `Req.RawWebRequest.Host` | Delegates to `TMormotRawRequest.GetHost` | PATCH-REQ-8 |
| `Req.RawWebRequest.PathInfo` | Delegates to `TMormotRawRequest.GetPathInfo` | PATCH-REQ-8 |
| `Req.RawWebRequest.GetFieldByName('X')` | Linear scan of `InHeaders` in `TMormotRawRequest` | PATCH-REQ-8 |
| `Req.RawWebRequest.RemoteAddr` | Delegates to `TMormotRawRequest.GetRemoteAddr` | PATCH-REQ-8 |

### THorseResponse surfaces

| Surface | How mORMot satisfies it | Patch |
|---|---|---|
| `Res.Send(text)` | Writes to `FCSBody` shadow field; bridge reads via `BodyText` property | PATCH-RES-4 |
| `Res.ContentType(ct)` | Writes to `FCSContentType` shadow field; bridge reads via `CSContentType` | PATCH-RES-4 |
| `Res.Status(code)` | Writes to `FCSStatusCode` shadow field; bridge reads via `Status` | PATCH-RES-4 |
| `Res.AddHeader(n,v)` | Writes to `FCustomHeaders` dict/list; bridge emits via `BuildHeaders` | PATCH-RES-1/3 |
| `Res.SendFile(path)` | Writes to `FCSContentStream`; bridge reads via `ContentStream` | PATCH-RES-4 |
| `Res.RawWebResponse` | `TMormotWebResponse` adapter — non-nil always on mORMot path | PATCH-RES-6 |
| `Res.RawWebResponse.SetCustomHeader(n,v)` | Writes to `TInterfacedWebResponse.CustomHeaders: TStrings`; bridge reads via COMPAT-1 | PATCH-RES-6 |
| `Res.RawWebResponse.Content` | COMPAT-1 fallback in `WriteBody` — read when shadow body is empty | COMPAT-1 |
| `Res.RawWebResponse.ContentType` | COMPAT-1 fallback in `Flush` — read when `CSContentType` is empty | COMPAT-1 |
