# Architecture Reference — `horse-provider-mormot`

Visual reference for the request lifecycle, class hierarchy, threading model, and security hardening of the mORMot2 Horse provider. Read alongside `implementation-notes.md`.

---

## Request lifecycle

```
HTTP/1.1 request (IOCP / epoll kernel event)
      │
      ▼
THttpServer (mORMot2 thread-pool thread)
      │   mORMot owns the socket, the thread, and the THttpServerRequestAbstract
      │   object. InContent (RawByteString) is already fully buffered here.
      ▼
TMormotHandler.Process(Ctxt: THttpServerRequestAbstract): cardinal
      │
      ├─ [SEC-30] TInterlocked.Increment(FActiveRequests)
      │           if = 1 → FDrainEvent.ResetEvent
      │
      ├─ [SEC-29] TMormotRequestBridge.Validate(Ctxt)
      │           validates method, URL length, Host header,
      │           CL+TE smuggling, Transfer-Encoding value
      │           → rvMethodNotAllowed  → SendError(405)  ──┐
      │           → rvBadRequest        → SendError(400)  ──┤
      │           → rvOK                                    │
      │                                                     │
      ├─ THorseContextPool.Acquire  ◄── pre-warmed pool     │
      │           (no heap allocation on hot path)          │
      │                                                     │
      ├─ TMormotRequestBridge.Populate(Ctxt, Ctx.Request)   │
      │     ├─ AHorseReq.Populate(method, methodType,       │
      │     │        path, contentType, remoteAddr)          │
      │     │        → PATCH-REQ-3 shadow fields            │
      │     ├─ Header parsing (SEC-13 guards)               │
      │     ├─ Query param parsing (SEC-18 guards)          │
      │     ├─ Cookie parsing                               │
      │     ├─ Form-body parsing (x-www-form-urlencoded)    │
      │     ├─ AHorseReq.SetBodyString(...)   PATCH-REQ-9  │
      │     └─ AHorseReq.SetCSRawWebRequest(              │
      │              TMormotWebRequest.Create(Ctxt))        │
      │              PATCH-REQ-8                           │
      │                                                     │
      ├─ Ctx.Response.SetCSRawWebResponse(               │
      │        TMormotWebResponse.Create(Ctxt))             │
      │        PATCH-RES-6                                 │
      │                                                     │
      ├─ THorse.Execute(Ctx.Request, Ctx.Response)          │
      │     (middleware + routing pipeline)                 │
      │     ├─ on EHorseCallbackInterrupted → swallow       │
      │     │        BUG-2: normal pipeline-end signal      │
      │     ├─ on EHorseException → structured 4xx/5xx      │
      │     │        SEC-31                                 │
      │     └─ on Exception → log + 500 JSON               │
      │              SEC-31 (no stack leak)                 │
      │                                                     │
      ├─ TMormotResponseBridge.Flush(                      │
      │        Ctx.Response, Ctxt, ServerBanner)            │
      │     ├─ security headers (SEC-22/23/5)              │
      │     ├─ app headers (CustomHeaders dict)             │
      │     ├─ COMPAT-1 fallback from RawWebResponse        │
      │     ├─ CRLF-strip on all header values  SEC-19      │
      │     ├─ hop-by-hop filter  SEC-20                    │
      │     ├─ Ctxt.OutContent := body                      │
      │     └─ returns cardinal (HTTP status)               │
      │                                                     │
      ├─ THorseContextPool.Release(Ctx)                     │
      │     └─ Ctx.Reset → Req.Clear + Res.Clear            │
      │                                                     │
      └─ [SEC-30] TInterlocked.Decrement(FActiveRequests)   │
                  if = 0 → FDrainEvent.SetEvent             │
                  ◄────────────────────────────────────────-┘
      │
      ▼
Return cardinal status to mORMot
(mORMot sends Ctxt.OutContent/OutContentType/OutCustomHeaders to client)
```

---

## Class hierarchy

### Provider class

```
THorseProviderAbstract   (Horse.Provider.Abstract)
      │
      └─ THorseProviderMormot   (Horse.Provider.Mormot)
            │  class vars: FServer, FConfig, FPort,
            │              FStopEvent, FRunning,
            │              FHandler, FActiveRequests, FDrainEvent
            │
            ├─ [shape: Console]  THorseProviderMormot   (direct)
            ├─ [shape: VCL]      THorseProviderMormotVCL → TfrmHorseMormotVCLHost
            └─ [shape: Daemon]   THorseProviderMormotDaemon
                   {$IFDEF MSWINDOWS} → THorseMormotService (TService base)
                   {$ELSE}           → THorseMormotLinuxDaemonApp.Run
```

### Request adapter chain

```
THttpServerRequestAbstract   (mormot.net.server)
      │  InContent: RawByteString  (fully buffered, mORMot-owned)
      │  InHeaders: RawUtf8        (CRLF-delimited header block)
      │  Method, Url, Host, RemoteIP: RawUtf8
      │
      ▼
TMormotRawRequest : TInterfacedObject, IHorseRawRequest
      │  (~15 methods wrapping ACtxt.* fields)
      │  ParsePath — lazy split of Url into PathInfo + QueryString
      │  GetFieldByName — linear scan of InHeaders string
      │  GetContent — cached UTF-8 decode of InContent
      │
      ▼
TInterfacedWebRequest   (Horse.Provider.RawAdapters)
      │  delegates all 30+ TWebRequest abstract stubs to IHorseRawRequest
      │
      ▼
TMormotWebRequest : TInterfacedWebRequest
      │  1-line constructor: inherited Create(TMormotRawRequest.Create(ACtxt))
      │
      ▼
THorseRequest.FCSRawWebRequest   (set by SetCSRawWebRequest — PATCH-REQ-8)
      │
      ▼
THorseRequest.RawWebRequest → returns TWebRequest (unchanged public API)
      │
      ▼
Middleware (Horse.CORS, horse-jwt, etc.) — works unchanged
```

### Response adapter chain

```
THttpServerRequestAbstract   (same object as request — mORMot unified design)
      │  OutContent:       RawByteString   (bridge writes here)
      │  OutContentType:   RawUtf8
      │  OutCustomHeaders: RawUtf8
      │
      ▼
TMormotRawResponse : TInterfacedObject, IHorseRawResponse
      │  (~1 method — SetCustomHeader is a no-op; headers are written at
      │   Flush time by TMormotResponseBridge from CustomHeaders TStrings)
      │
      ▼
TInterfacedWebResponse   (Horse.Provider.RawAdapters)
      │  CustomHeaders: TStrings — receives SetCustomHeader calls
      │
      ▼
TMormotWebResponse : TInterfacedWebResponse
      │  1-line constructor: inherited Create(TMormotRawResponse.Create(ACtxt))
      │
      ▼
THorseResponse.FCSRawWebResponse   (set by SetCSRawWebResponse — PATCH-RES-6)
      │
      ▼
THorseResponse.RawWebResponse → returns TWebResponse (unchanged public API)
      │
      ▼
Middleware (Horse.CORS calls Res.RawWebResponse.SetCustomHeader) — works unchanged
```

### Context pool

```
THorseContextPool   (Horse.Provider.Mormot.Pool)
      │  FPool: array[0..POOL_MAX_SIZE-1] of THorseContext
      │  FLock: TCriticalSection
      │  POOL_WARMUP_SIZE = 32   (created at unit initialisation)
      │  POOL_MAX_SIZE    = 512  (hard ceiling under burst load)
      │
      ├─ Acquire → find FInUse=False, mark FInUse=True, return
      │            (or Create a new one up to POOL_MAX_SIZE)
      └─ Release → Ctx.Reset, mark FInUse=False

THorseContext
      ├─ FRequest:  THorseRequest   (created in constructor)
      └─ FResponse: THorseResponse  (created in constructor)

THorseContext.Reset
      ├─ FRequest.Clear   — wipes shadow fields, clears dicts in-place
      └─ FResponse.Clear  — wipes shadow fields, clears CustomHeaders in-place
```

---

## Threading model

### mORMot vs CrossSocket

| Aspect | mORMot2 | CrossSocket |
|---|---|---|
| I/O model | IOCP (Windows) / epoll (Linux) — same primitives | IOCP (Windows) / epoll (Linux) |
| Thread pool | Built-in `THttpServer` thread pool (default 32) | Horse's own `THorseWorkerPool` (4–64 threads) |
| OnRequest | Synchronous method-of-object called on a pool thread | Async closure; CrossSocket callback is on an IO thread |
| `THorseWorkerPool` | **Not needed** — mORMot already pools threads per request | Required — CrossSocket's IO threads must not block |
| Body buffering | `InContent: RawByteString` fully buffered by mORMot | `ICrossHttpRequest.Body: TStream` — transport-owned stream |
| Thread safety | mORMot thread calls `THorseProviderMormot.ExecutePipeline` directly | CrossSocket IO thread dispatches to worker pool |

### Active tracking (SEC-30)

```
             Acquire                               Release
              │                                      │
TInterlocked.Increment(FActiveRequests)     TInterlocked.Decrement(FActiveRequests)
              │ = 1?                                 │ = 0?
              ▼                                      ▼
     FDrainEvent.ResetEvent           FDrainEvent.SetEvent
     (mark drain in progress)         (all requests done → Stop can exit)

Stop:
  1. FRunning := False
  2. FServer.Free   (terminates all mORMot IO threads)
  3. FHandler.Free
  4. if FActiveRequests > 0 → FDrainEvent.WaitFor(DrainTimeoutMs)
  5. FreeAndNil(FDrainEvent)
  6. FStopEvent.SetEvent  (unblock main thread in console apps)
```

---

## TMormotHandler bridge

mORMot's `OnRequest` callback must be a **method of an object**, not a class method or a standalone procedure. `THorseProviderMormot.ExecutePipeline` is a class method and cannot be assigned directly to `FServer.OnRequest`. `TMormotHandler` bridges this:

```pascal
type
  TMormotHandler = class
    function Process(Ctxt: THttpServerRequestAbstract): cardinal;
  end;

function TMormotHandler.Process(Ctxt: THttpServerRequestAbstract): cardinal;
begin
  Result := THorseProviderMormot.ExecutePipeline(Ctxt);
end;
```

`FHandler: TObject` keeps the instance alive for the lifetime of the server. `Stop` frees `FServer` first (joins all mORMot threads), then frees `FHandler` — this order is critical: freeing `FHandler` while mORMot threads are still calling `Process` would be a use-after-free.

---

## Security hardening tags

| Tag | Where | What it does |
|---|---|---|
| **SEC-5** | Response bridge | `Server:` header value from `FConfig.ServerBanner`; defaults to `unknown` if empty |
| **SEC-12** | `TMormotRequestBridge.Validate` | Rejects requests with both `Content-Length` and `Transfer-Encoding` present (HTTP request smuggling guard) |
| **SEC-13** | `TMormotRequestBridge.Populate` | Header count limit (100), name length limit (256 B), value length limit (8 KB), CRLF in name rejected |
| **SEC-14** | `TMormotRequestBridge.Validate` | URL length limit: 8 KB |
| **SEC-15** | `TMormotRequestBridge.Validate` | HTTP method allowlist: GET POST PUT DELETE PATCH HEAD OPTIONS |
| **SEC-17** | `TMormotRequestBridge.Validate` | Host header: missing or containing non-printable-ASCII → 400 |
| **SEC-18** | `TMormotRequestBridge.Populate` | Query string key/value size limits: 2 KB each |
| **SEC-19** | Response bridge `SanitiseHeaderValue` | Strips CR, LF, NUL from all response header values |
| **SEC-20** | Response bridge `IsHopByHopHeader` | Filters Connection, Keep-Alive, Transfer-Encoding, Upgrade, Server (managed by mORMot) |
| **SEC-21** | Response bridge `Flush` | Content-Type from `AHorseRes.CSContentType` shadow field; COMPAT-1 fallback |
| **SEC-22** | Response bridge `BuildHeaders` | `X-Content-Type-Options: nosniff` always present |
| **SEC-23** | Response bridge `BuildHeaders` | `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`, `Cache-Control: no-store` |
| **SEC-29** | `TMormotRequestBridge.Validate` | Validate-before-pool: invalid requests are rejected *before* `THorseContextPool.Acquire` is called — the pipeline is never entered, no pool context is consumed |
| **SEC-30** | `ExecutePipeline` + `Stop` | Active-request counter (`FActiveRequests`) + drain event: `Stop` waits up to `DrainTimeoutMs` for active requests to complete |
| **SEC-31** | `ExecutePipeline` exception handlers | Pipeline exceptions return structured JSON (never stack traces); `Exception` branch logs to `ErrOutput` and returns 500 |
| **SEC-32** | `InternalListen` | Double-start guard: if `FServer` is assigned when `Listen` is called, `Stop` is called first (with full drain) before the new server starts |
| **BUG-2** | `ExecutePipeline` | `EHorseCallbackInterrupted` caught explicitly — this is Horse's normal pipeline-end signal; if it falls into the generic `Exception` handler every request logs as an error and returns a spurious 500 |

---

## Differences from the CrossSocket provider

| Aspect | mORMot2 provider | CrossSocket provider |
|---|---|---|
| Socket I/O | mORMot2 `THttpServer` (built-in) | `TCrossHttpServer` from Delphi-Cross-Socket |
| Thread pool | mORMot's own (default 32 threads) | `THorseWorkerPool` (4–64 Horse worker threads) |
| Body type on request | `RawByteString` (value copy, mORMot-owned) | `TStream` (pointer into CrossSocket's receive buffer) |
| Body ownership | mORMot owns; bridge uses it safely; FBody is always nil in pool | CrossSocket owns; `FBody` is non-owning; never call `Body(nil)` (FIX-POOL-1) |
| `SetBodyString` | Called with `Utf8ToString(RawUtf8(InContent))` | Called with decoded stream content |
| FBody in pool Reset | Always nil (no stream to track) | Always nil (non-owning ref — FIX-POOL-1 / SEC-9) |
| Response flush | Synchronous writes to `Ctxt.Out*` fields; returns cardinal | Async: calls `ACrossRes.Send` / `SetHeader` |
| `TMormotHandler` | Required (method-of-object bridge) | Not required (closure assigned to `OnRequest`) |
| Validation split | `Validate` (SEC-29) + `Populate` (two separate methods) | `TRequestBridge.Populate` returns `TRequestValidationResult` |
| http.sys option | Can swap `THttpServer` for `THttpApiServer` (same interface) | No equivalent |
| FPC support | Yes — dual `{$IF DEFINED(FPC)}` throughout | Yes — same dual-compilation pattern |
