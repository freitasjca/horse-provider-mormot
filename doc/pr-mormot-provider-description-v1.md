## Additive changes to support mORMot2 high-performance provider

> This provider and the accompanying Horse patches use the same fork patches already submitted with the CrossSocket provider PR ([horse-provider-crosssocket](https://github.com/freitasjca/horse-provider-crosssocket)). If that PR has been merged, no additional Horse-level changes are required. The mORMot provider is an independent transport option that sits beside CrossSocket — both providers use the same hybrid adapter architecture and the same Horse fork patches.

---

### Context

We have developed a new provider for Horse, [horse-provider-mormot](https://github.com/freitasjca/horse-provider-mormot), that replaces the Indy transport layer with [mORMot2](https://github.com/synopse/mORMot2). This brings **IOCP/epoll async I/O**, **security hardening** (pre-pipeline validation, active-request drain tracking, structured JSON errors, double-start guard) and **broad compiler support** including FPC 3.2+ and Delphi 7 through 12.3 Athens.

The provider uses the **same Horse fork patches** as the CrossSocket provider. All existing Horse projects, providers, and official middlewares continue to compile and run without any changes.

---

### Why mORMot2 as a Horse transport

| Advantage | Detail |
|---|---|
| Async I/O | IOCP (Windows) / epoll (Linux) / kqueue (macOS) — same kernel primitives as CrossSocket |
| Mature codebase | 15+ years of production use; thousands of production deployments |
| Broad compiler support | Delphi 7 through 12.3 Athens, FPC 3.2.0+ |
| Cross-platform | Windows, Linux, macOS, BSD |
| http.sys integration | `THttpApiServer` uses the Windows kernel HTTP stack; swap requires zero code changes in Horse routes |
| No CnPack dependency | Unlike CrossSocket, mORMot2 has no third-party library dependency for standard HTTP |
| Pure Pascal | No compiled C libraries for basic HTTP; OpenSSL is optional for TLS |
| Built-in thread pool | mORMot manages its own thread pool (default 32) — no `THorseWorkerPool` needed in Horse |

---

### How to activate the provider

#### Step 1 — Include the provider unit

```pascal
uses
  Horse,
  Horse.Provider.Mormot;   // activates mORMot2 transport
```

> Once `Horse.pas` is patched to route `HORSE_PROVIDER_MORMOT`, add:
> ```
> HORSE_PROVIDER_MORMOT
> ```
> to **Project Options → Conditional defines** and remove the explicit `uses Horse.Provider.Mormot`.

#### Step 2 — Minimal application code

```pascal
program MyMormotServer;

{$APPTYPE CONSOLE}

uses
  Horse,
  Horse.Provider.Mormot;

begin
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain').Send('pong');
    end);

  THorse.Listen(9000);
end.
```

#### Step 3 — Advanced configuration

```pascal
var
  Config: THorseMormotConfig;
begin
  Config              := THorseMormotConfig.Default;
  Config.ThreadPool   := 64;             // increase thread pool for slow handlers
  Config.MaxBodyBytes := 16777216;       // 16 MB body limit
  Config.DrainTimeoutMs := 10000;        // 10 s graceful drain on shutdown
  Config.ServerBanner   := 'MyServer/1.0';

  THorseProviderMormot.ListenWithConfig(9000, Config);
end.
```

---

### Application-type wrappers (PATCH-HORSE-2)

Five per-shape server projects are included in `samples/tests/` exercising every supported combination:

| Shape | Unit | Lifecycle helper |
|---|---|---|
| Console (Delphi) | `Horse.Provider.Mormot` | `SetConsoleCtrlHandler` → `THorse.StopListen` |
| VCL (Delphi) | `Horse.Provider.Mormot.VCL` | `TfrmHorseMormotVCLHost` — auto-wired `FormCreate`/`FormClose` |
| Windows Service (Delphi) | `Horse.Provider.Mormot.Daemon` | `THorseMormotService` — worker-thread `Listen`; SCM-safe |
| Linux daemon (Delphi Linux64) | `Horse.Provider.Mormot.Daemon` | `THorseMormotLinuxDaemonApp.Run` — SIGTERM/SIGINT → drain |
| Console (FPC / Lazarus) | `Horse.Provider.Mormot` | `fpSignal` handlers → `THorse.StopListen` |
| Linux daemon (FPC) | `Horse.Provider.Mormot.Daemon` | `THorseMormotLinuxDaemonApp.Run` |

All six shapes register the same 32 test routes and are exercised by the same shared `HorseCSTestClient.dpr` used by the CrossSocket provider's test suite.

---

### Security hardening

The provider enforces the same security contract as the CrossSocket provider. All checks happen **before** a context object is acquired from the pool — invalid requests never enter the Horse pipeline.

| Tag | Check |
|---|---|
| **SEC-29** | Validate-before-pool: method allowlist, URL length (8 KB), Host header (required, printable ASCII), CL+TE conflict (HTTP request smuggling), Transfer-Encoding value |
| **SEC-30** | Active-request counter (`FActiveRequests`) + drain event: `Stop` waits up to `DrainTimeoutMs` for active requests to complete |
| **SEC-31** | All pipeline exceptions return structured JSON; `Exception` branch logs to `ErrOutput` and returns 500 — stack traces never reach clients |
| **SEC-32** | Double-start guard: a second `Listen` call stops the previous server (with full drain) before binding the new one |
| **BUG-2** | `EHorseCallbackInterrupted` caught explicitly — Horse's normal pipeline-end signal; not logged as an error |
| **SEC-19** | CRLF-stripping on all response header values |
| **SEC-20** | Hop-by-hop header filter (Connection, Transfer-Encoding, Upgrade, Server managed by mORMot) |
| **SEC-22/23** | `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`, `Cache-Control: no-store` injected on every response |

---

### Performance characteristics

#### Why mORMot2 is faster than Indy

mORMot2 uses the same IOCP (Windows) / epoll (Linux) kernel primitives as CrossSocket. The Indy provider allocates one blocking OS thread per connection; mORMot manages a fixed thread pool (default 32) shared across all connections:

| Aspect | Indy (one thread per connection) | mORMot2 (IOCP / epoll) |
|---|---|---|
| Thread count at 1 000 concurrent connections | ~1 000 threads → ~1–2 GB reserved stack | 32 threads (configurable) |
| Context switching | High — OS schedules hundreds of idle threads | Near zero — threads only run when data is ready |
| Memory per request | New `THorseRequest`/`THorseResponse` pair allocated every request | Context pool (`THorseContextPool`) recycles pre-warmed objects — no allocator on hot path |
| Keep-alive | Each idle connection holds a thread | Idle keep-alive connections cost no thread |

#### mORMot2 vs CrossSocket

Both providers use IOCP/epoll and a context object pool. Key differences:

| Aspect | mORMot2 | CrossSocket |
|---|---|---|
| Thread pool | Built-in (32 threads by default) | `THorseWorkerPool` (4–64 Horse threads) |
| No external dependency | ✅ Pure Pascal | ❌ Delphi-Cross-Socket + CnPack |
| Compiler support | Delphi 7+, FPC 3.2+ | Delphi 10.2+, FPC 3.2+ |
| http.sys (Windows) | ✅ `THttpApiServer` (zero code change) | ❌ Not available |
| Callback style | Method of object (`TMormotHandler.Process`) | Closure on IO thread → worker pool |

Choose **mORMot2** when: no third-party library dependency is acceptable, Delphi 7/XE/XE2 support is required, or Windows http.sys kernel-mode HTTP is desired.

Choose **CrossSocket** when: native async IOCP/epoll control is preferred, or the project already depends on Delphi-Cross-Socket.

---

### Middleware compatibility

All official Horse middlewares work without source changes:

| Middleware | Status | Mechanism |
|---|---|---|
| **horse-cors** | ✅ Works | `Req.RawWebRequest.Method` via `TMormotWebRequest` (PATCH-REQ-8); `Res.RawWebResponse.SetCustomHeader` via `TMormotWebResponse` + COMPAT-1 flush (PATCH-RES-6) |
| **horse-jhonson** | ✅ Works | `Res.Send` / `Res.ContentType` → shadow fields (PATCH-RES-4); COMPAT-1 fallback for FPC path |
| **horse-jwt** | ✅ Works | `Req.Headers['Authorization']` → nil-guarded shadow field (PATCH-REQ-3) |
| **horse-logger** | ✅ Works | `Req.Method`, `Req.PathInfo`, `Res.Status` → shadow fields |
| **horse-basic-authenticator** | ✅ Works | Same as JWT |
| **horse-request-guard** | ✅ Works (redundant) | Pre-pipeline SEC-29 already covers the same checks; middleware is harmless defence-in-depth |
| **horse-security-headers** | ✅ Works (additive) | Response bridge already injects these; middleware adds them a second time — harmless |

---

### Required Horse patches

The mORMot provider requires the same Horse fork patches as the CrossSocket provider. If the CrossSocket PR has been merged, no additional changes are needed. For completeness:

#### `Horse.Request.pas`

- **Parameterless constructor** — allows the context pool to pre-allocate request objects.
- **`Clear` procedure** (PATCH-REQ-2) — zero-allocation pool reset; sets `FBody := nil` without freeing (mORMot body is `RawByteString` — no stream to free).
- **`Populate` procedure** (PATCH-REQ-3) — injects shadow fields (`FCSMethod`, `FCSMethodType`, `FCSPathInfo`, `FCSContentType`, `FCSRemoteAddr`) without requiring a live `TWebRequest`.
- **`SetBodyString` + `FBodyString`** (PATCH-REQ-9) — caches the decoded UTF-8 body so `Req.Body : string` is O(1) and idempotent across multiple reads.
- **`SetCSRawWebRequest`** (PATCH-REQ-8) — assigns `TMormotWebRequest` adapter so `Req.RawWebRequest` returns a non-nil object for middleware like Horse.CORS.
- **Nil-guards on existing accessors** — `Body`, `Host`, `MethodType`, `PathInfo`, `ContentType`, `InitializeQuery`, `InitializeCookie`, `InitializeContentFields`, `Headers` all return shadow fields when `FWebRequest = nil`.

#### `Horse.Response.pas`

- **`CustomHeaders` property** (PATCH-RES-1/3) — exposes `FCustomHeaders` for the response bridge to iterate app-set headers.
- **`BodyText`, `ContentStream`, `CSContentType` properties** (PATCH-RES-4) — shadow field read-back for the response bridge.
- **`Clear` procedure** (PATCH-RES-2) — resets shadow fields; clears `FCustomHeaders` in-place; frees `FCSRawWebResponse` adapter.
- **`SetCSRawWebResponse`** (PATCH-RES-6) — assigns `TMormotWebResponse` adapter so `Res.RawWebResponse` returns a non-nil object.
- **Nil-guards on existing setters** — `Send`, `Status`, `ContentType`, `AddHeader`, `RemoveHeader`, `RedirectTo`, `SendFile`, `Download` all write to shadow fields when `FWebResponse = nil`.

#### `Horse.Provider.Abstract.pas`

- **`ListenWithConfig` virtual class method** — accepts `THorseMormotConfig` (analogous to `THorseCrossSocketConfig`).
- **`Execute` virtual class method** — runs the Horse middleware + route pipeline.

#### New units (if not already merged with CrossSocket PR)

- **`Horse.Provider.RawInterfaces.pas`** — `IHorseRawRequest` (~15 methods) + `IHorseRawResponse` (~1 method).
- **`Horse.Provider.RawAdapters.pas`** — `TInterfacedWebRequest` / `TInterfacedWebResponse` generic adapters (stub all 30+ `TWebRequest`/`TWebResponse` abstract methods).

#### `Horse.pas` (PATCH-HORSE-2 extension — one new branch)

```pascal
// Stage 2 — Provider selection (add alongside HORSE_PROVIDER_CROSSSOCKET branch)
{$ELSEIF DEFINED(HORSE_PROVIDER_MORMOT)}
  Horse.Provider.Mormot,

// THorseProvider type alias chain
{$ELSEIF DEFINED(HORSE_PROVIDER_MORMOT)}
  THorseProvider = Horse.Provider.Mormot.THorseProviderMormot;
```

---

### Testing and verification

**Integration test suite — same 32 tests as CrossSocket, all passing:**

- HTTP methods: GET, POST, PUT, DELETE, PATCH, HEAD
- Routing: single path parameter, two path parameters, query string
- Cookies: `Set-Cookie` response, `Cookie` request echo
- Body: JSON echo, multipart upload, file download, custom header echo
- Error paths: 404, explicit 4xx/5xx with JSON body
- Response integrity: `Content-Type` header, 65 536-byte response without truncation
- **Pool regression:** nil-body POST, 64 KB body, sequential body isolation, 4 concurrent POST requests
- **RawWebRequest adapter** (PATCH-REQ-8): method, host, pathInfo, headers, remoteAddr via `Req.RawWebRequest`
- **CORS compatibility:** `OPTIONS` preflight returns 204 + `Access-Control-Allow-Origin`; `GET` returns route body
- **PATCH-REQ-9 double-read:** `Req.Body` called twice returns identical cached string (`"equal":true`)
- **COMPAT-1 shadow-field precedence:** `Res.RawWebResponse.Content` written before `Res.Send` — shadow field wins

**Application-type shapes verified:**

| Shape | Status |
|---|---|
| Delphi Console (Win64) | ✅ Builds, 32 tests pass |
| Delphi VCL (Win64) | ✅ Builds, form shows, 32 tests pass |
| Delphi Windows Service (Win64) | ✅ Builds, installs, starts, 32 tests pass, stops cleanly |
| Delphi Linux64 daemon | ✅ Builds for Linux64; SIGTERM → clean drain |
| FPC Console (Linux) | ✅ Builds with mORMot2 + FPC 3.2.2 |
| FPC Daemon (Linux) | ✅ Builds; systemd SIGTERM → clean drain |

---

### Summary of new files

**In `horse-provider-mormot/src/`** (no changes to Horse source beyond what CrossSocket already submitted):

| File | Role |
|---|---|
| `Horse.Provider.Mormot.Config.pas` | `THorseMormotConfig` record with safe defaults |
| `Horse.Provider.Mormot.Pool.pas` | `THorseContextPool` — 512-slot pre-warmed context pool |
| `Horse.Provider.Mormot.RawRequest.pas` | `TMormotRawRequest` implementing `IHorseRawRequest` (~15 methods) |
| `Horse.Provider.Mormot.RawResponse.pas` | `TMormotRawResponse` implementing `IHorseRawResponse` |
| `Horse.Provider.Mormot.WebRequestAdapter.pas` | `TMormotWebRequest` — thin `TInterfacedWebRequest` subclass |
| `Horse.Provider.Mormot.WebResponseAdapter.pas` | `TMormotWebResponse` — thin `TInterfacedWebResponse` subclass |
| `Horse.Provider.Mormot.Request.pas` | `TMormotRequestBridge` — validation + shadow-field population |
| `Horse.Provider.Mormot.Response.pas` | `TMormotResponseBridge` — security headers + body flush to `Ctxt.Out*` |
| `Horse.Provider.Mormot.pas` | `THorseProviderMormot` — main provider class |
| `Horse.Provider.Mormot.VCL.pas` | `TfrmHorseMormotVCLHost` — VCL form base |
| `Horse.Provider.Mormot.Daemon.pas` | `THorseMormotService` (Windows) + `THorseMormotLinuxDaemonApp` (POSIX) |

**One-line addition to `Horse.pas`** (PATCH-HORSE-2 extension for `HORSE_PROVIDER_MORMOT`):

| Existing file changed | Change |
|---|---|
| `Horse.pas` | Two `{$ELSEIF DEFINED(HORSE_PROVIDER_MORMOT)}` branches — one in the `uses` chain, one in the `THorseProvider` alias chain |

---

### Note on dependencies

mORMot2 must be installed separately. It is not available via Boss. Installation:

```bash
# Clone
git clone https://github.com/synopse/mORMot2.git

# Add to Delphi search path:
#   <mORMot2>/src
#   <mORMot2>/src/core
#   <mORMot2>/src/net
#   <mORMot2>/src/lib
```

For projects using `boss install`:

```json
{
  "name": "my-horse-mormot-server",
  "dependencies": {
    "horse": "github.com/freitasjca/horse",
    "horse-provider-mormot": "github.com/freitasjca/horse-provider-mormot"
  }
}
```

mORMot2 itself must be added to the compiler search path manually (no Boss package) — include `<mORMot2>/src/core` and `<mORMot2>/src/net` as a minimum.

---

We would be very happy to discuss any aspect of these changes, adjust scope, or split into smaller PRs if preferred. The mORMot provider is a companion to the CrossSocket provider — users who already run CrossSocket get an additional transport option with no Horse-level changes; users who prefer mORMot's mature codebase and http.sys support can adopt it independently. Thank you for maintaining such a fantastic framework!
