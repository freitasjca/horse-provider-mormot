# Implementation Notes — `horse-provider-mormot`

Key design decisions, mORMot-specific constraints, and differences from the CrossSocket provider. Read alongside `architecture-diagrams.md` before modifying any source file.

---

## RawUtf8 ↔ string conversion boundary

mORMot uses `RawUtf8` (UTF-8 `AnsiString`) for all string properties. Horse uses `string` (UTF-16 on Delphi, UTF-8 on FPC). Convert exactly at the mORMot/Horse boundary — never store `RawUtf8` in Horse's `string` fields without conversion, as the codepage mismatch silently corrupts non-ASCII characters on Delphi.

```pascal
// mORMot → Horse  (read from request)
LMethod := Utf8ToString(ACtxt.Method);

// Horse → mORMot  (write to response)
ACtxt.OutContent := StringToUtf8(LBody);

// Body: RawByteString → string
SetBodyString(Utf8ToString(RawUtf8(ACtxt.InContent)));
```

`Utf8ToString` and `StringToUtf8` are defined in **`mormot.core.unicode` only** — `mormot.core.base` exports the `RawUtf8` / `RawByteString` types but not the conversion functions (see the `mormot.core.unicode.pas` reference at the top of `mormot.core.base.pas`). Any unit calling either function must include `mormot.core.unicode` in its uses clause; relying on transitive visibility via `mormot.net.server` will not work because Delphi/FPC unit scoping is not transitive across explicit `uses` lists.

The cast `RawUtf8(ACtxt.InContent)` is safe because `RawByteString` and `RawUtf8` are both `AnsiString` variants and mORMot guarantees `InContent` contains UTF-8 text when the request body is text (declared by `Content-Type: application/json; charset=utf-8`). For binary bodies the cast is wrong but harmless for the purposes of `SetBodyString` since binary content is not expected to be read as a UTF-8 string.

---

## Body ownership — the key difference from CrossSocket

This is the single most important difference between the two providers. Get this wrong and you get double-free crashes or memory leaks.

### CrossSocket body ownership

```
ICrossHttpRequest.Body : TStream
      │  Owned by CrossSocket's TCrossHttpRequest
      │  Lives as long as the mORMot request context lives
      │
THorseRequest.FBody := Body  (non-owning pointer — NEVER free this)
      │
THorseRequest.Clear → FBody := nil  (NO Free call — FIX-POOL-1 / SEC-9)
      │
TCrossHttpRequest.Destroy → FreeAndNil(FBody)  (CrossSocket frees it)
```

### mORMot body ownership

```
THttpServerRequestAbstract.InContent : RawByteString
      │  Owned by mORMot. There is no TStream — it is a value type string.
      │  The mORMot provider NEVER creates a stream for FBody.
      │
THorseRequest.SetBodyString(Utf8ToString(InContent))
      │  → cached in FBodyString; Req.Body : string is O(1) and idempotent
      │
THorseRequest.FBody → always nil on the mORMot path
      │
THorseRequest.Clear → FBody := nil  (already nil — no-op, no free)
```

**Rule:** On the mORMot path, `FBody` is always `nil`. Do not assign a `TStream` to `FBody` via `Body(LStream)` unless you also track the stream externally and free it after `Clear`. The `Body(AObject)` setter frees the existing `FBody` first — on a CrossSocket pool that would double-free CrossSocket's transport stream. The mORMot pool's `Reset` path uses `FRequest.Clear` (which sets `FBody := nil` without freeing), exactly like CrossSocket.

---

## Multipart upload stream ownership — `[FOLLOW-UP-MEM-1]`

A second ownership divergence appears in multipart/form-data handling. Horse's `THorseCoreParam.AddStream(AKey, AStream)` (Horse.Core.Param.pas:120) writes the stream into `FFiles: TDictionary<string, TStream>` — and that dictionary is a **plain `TDictionary`, not a `TObjectDictionary([doOwnsValues])`**. `THorseCoreParam.Destroy` does `FreeAndNil(FFiles)`, which frees the dictionary structure but leaves the `TStream` values orphaned.

### CrossSocket sidesteps the issue

```
ICrossHttpRequest.Body : THttpMultiPartFormData (when multipart)
      │  THttpMultiPartFormData owns the per-part streams
      │
ContentFields.AddStream(Field.Name, Field.Value)   ← non-owning pointer
      │
TCrossHttpRequest.Destroy → THttpMultiPartFormData.Destroy → frees the streams
```

CrossSocket can pass a non-owning pointer into Horse because the streams have an external owner — `THttpMultiPartFormData` — whose lifetime is tied to the request itself. Horse's FFiles holds a borrowed reference, no leak.

### mORMot has no equivalent owner

```
mormot.core.buffers.MultiPartFormDataDecode → TMultiPartDynArray
      │  Each part is a RECORD with an inline RawByteString Content field.
      │  No TStream object exists. No owning aggregate exists.
      │
TMormotRequestBridge.PopulateMultipartFields:
      │
      │  for each part with FileName <> '':
      │    LStream := TMemoryStream.Create;       ← synthesised by the bridge
      │    LStream.WriteBuffer(part.Content, …);
      │    ContentFields.AddStream(part.Name, LStream);
      │
      │  → FFiles now holds LStream
      │  → THorseRequest.Clear → ContentFields.Destroy → FreeAndNil(FFiles)
      │  → LStream is LEAKED. FFiles is freed, but its TStream value isn't.
```

The bridge has to materialise a `TMemoryStream` because the test handler (and any realistic file-upload handler) reads via `Req.ContentFields.Field('file').AsStream`, which dispatches through `NewField → FFiles.TryGetValue` (Horse.Core.Param.pas:132). Routing through the string-dictionary path would corrupt non-UTF-8 binary payloads via `Utf8ToString`, so the stream path is the only correct choice — but it leaks the stream descriptor on every multipart upload.

### Current state

The leak is tagged `[FOLLOW-UP-MEM-1]` in a comment block inside `TMormotRequestBridge.PopulateMultipartFields` in `Horse.Provider.Mormot.Request.pas`. The behaviour is functionally correct (test 12 — POST /upload — passes) but each multipart-with-file request leaks one `TMemoryStream` of upload bytes until the process exits. On a server taking, say, 10 file uploads per second with 1 MB payloads, that is ~10 MB/s of accumulating memory — unsustainable for production deployments. For development, tests, and low-throughput services it is tolerable.

Plain text form fields are not affected — they go through the string-dictionary path and don't allocate a stream.

### The two proper fixes

**Option 1 — Pool-side tracking (local to mORMot provider, recommended near-term).**

Extend the pool's per-request bookkeeping with a stream tracker that the bridge populates and `Reset` drains. Approximate shape:

```pascal
// Horse.Provider.Mormot.Pool.pas
type
  THorseContext = class
  private
    FRequest:        THorseRequest;
    FResponse:       THorseResponse;
    FUploadStreams:  TList<TStream>;   // bridge-allocated multipart streams
  public
    procedure TrackUploadStream(AStream: TStream);
    procedure Reset;   // frees every stream in FUploadStreams, then clears it
  end;
```

The bridge then calls `LContext.TrackUploadStream(LStream)` after every `ContentFields.AddStream`, and `Pool.Reset` frees the streams before the request is returned to the pool. No upstream Horse changes required, ~15 lines.

**Option 2 — Horse upstream patch (correct long-term, broader impact).**

Change `Horse.Core.Param.pas` line 124 from:

```pascal
FFiles := TDictionary<string, TStream>.Create;
```

to:

```pascal
FFiles := TObjectDictionary<string, TStream>.Create([doOwnsValues]);
```

Single-line change, but it alters the ownership contract of every existing call to `AddStream` across every provider (Indy, CrossSocket, mORMot, plus any third-party). The CrossSocket bridge currently passes a non-owning pointer that would now be double-freed. Indy's file-upload behaviour would need re-examination. Worth pursuing as an upstream PR once the affected call sites are audited; until then, Option 1 is safer.

### Why this is documented here, not fixed inline

The Test 12 fix (synthesise `TMemoryStream`, hand to `AddStream`) was made urgent by the need to pass a green test before further work. The leak is a known correctness regression for production but doesn't block the test suite. Tracking it in this doc keeps it visible without inflating the immediate change set. The matching source comment (`[FOLLOW-UP-MEM-1]`) ensures `grep` from either side finds the full context.

---

## No THorseWorkerPool

The CrossSocket provider uses `THorseWorkerPool` (4–64 threads) because CrossSocket's I/O callback fires on an IOCP/epoll thread that must not block. The Horse pipeline runs on the worker pool, not on the I/O thread.

mORMot's `THttpServer` already manages its own thread pool (`THorseMormotConfig.ThreadPool`, default 32). Each `OnRequest` callback fires on one of those threads — it *can* block without stalling other connections. **No `THorseWorkerPool` is needed.** The mORMot provider calls `THorse.Execute` directly inside `TMormotHandler.Process`.

This simplification is safe and correct — but it means very slow route handlers can stall one of the 32 threads for the duration of the handler. Increase `THorseMormotConfig.ThreadPool` if you have handlers that block for long periods (DB queries, file I/O).

The same applies in `mskAsync` mode (`THttpAsyncServer`): mORMot dispatches each `OnRequest` on one of its own threads, so `THorse.Execute` may still run synchronously and block — there is still no need for `THorseWorkerPool`. But because the async backend has *far fewer* threads than the thread-pool backend (sized for event-loop R/W, not per-request), a blocking handler is proportionally more costly. Keep handlers non-blocking under `mskAsync`, or stay on `mskThreadPool` for blocking workloads.

---

## TCP_NODELAY — enabled by mORMot, no provider code

mORMot's `THttpServer` sets `TCP_NODELAY` (Nagle disabled) on its sockets by default, so the
provider adds **nothing** here. This is why mORMot was the one stack **immune** to the Linux/WSL
loopback artifact where CrossSocket and Indy were pinned at a ~44 ms/request floor (~2 270 RPS) until
they added `TCP_NODELAY` explicitly: on a keep-alive connection the small request/response ping-pong
collides with the kernel's ~40 ms delayed-ACK timer unless Nagle is off. No action is needed for the
mORMot provider; if you ever see that ~44 ms floor it is *not* this transport. (Background:
`horse-provider-crosssocket/bench/results/bench-analysis-report.md` §7.5.)

---

## Server backend selection — `THttpServer` vs `THttpAsyncServer`

`FServer` is typed as the shared base **`THttpServerSocketGeneric`**, so `InternalListen`
instantiates whichever concrete backend `AConfig.ServerKind` selects. Both backends declare
an **identical** `Create` signature (inherited from the base) and expose `OnRequest` /
`WaitStarted` on the base, so everything after construction is backend-agnostic:

```pascal
case AConfig.ServerKind of
  mskAsync:                         // THttpAsyncServer — mormot.net.async
    FServer := THttpAsyncServer.Create(
      StringToUtf8(IntToStr(APort)), nil, nil, '', AConfig.ThreadPool);
else // mskThreadPool (default)     // THttpServer — mormot.net.server
  FServer := THttpServer.Create(
    StringToUtf8(IntToStr(APort)), nil, nil, '', AConfig.ThreadPool);
end;
FServer.OnRequest := LHandler.Process;
FServer.WaitStarted(10);            // wait up to 10 s for the server to bind
```

Constructor parameter order (shared by both): port as `RawUtf8` (e.g. `'9000'`), `OnStart`,
`OnStop` (both unused), process description (logging only), then `ServerThreadPoolCount`.

`ServerThreadPoolCount` (fed from `AConfig.ThreadPool`, default 32) means **concurrent
request slots** for `THttpServer`, but **async R/W event-loop threads** for
`THttpAsyncServer` — size the latter like CPU cores, not client count.

Selection is runtime (`Cfg.ServerKind := mskAsync` before `ListenWithConfig`) or compile-time
(`HORSE_MORMOT_ASYNC` set project-wide flips `THorseMormotConfig.Default`). An explicit
`ServerKind` always wins over the define. See the README "Server backend" section.

`WaitStarted(10)` blocks until the server has bound to the port or 10 seconds have elapsed. Without this call, `Listen` may return before the port is actually listening, and the first request may get a connection-refused error.

The `FServer.Free` call in `Stop` joins all mORMot worker threads before returning (true for both backends) — it is safe to free `FHandler` immediately after.

---

## Loopback `RemoteIP` normalization (mORMot interop)

`Horse.Provider.Mormot.pas` sets one mORMot2 global flag at unit initialization:

```pascal
initialization
  RemoteIPLocalHostAsVoidInServers := False;
```

The flag lives in `mormot.net.sock.pas`. Default is `True`, with the documented behaviour:

> defines if a connection from the loopback should be reported as `''`
> - with default true, loopback connection will have no RemoteIP address (`''`)
> - or it will be explicitly `'127.0.0.1'` - if equals false

mORMot's reasoning is log hygiene — keeping `127.0.0.1` out of server logs that are dominated by external traffic. Horse's cross-provider contract is the opposite: `Req.RawWebRequest.RemoteAddr` must return the literal peer IP, the same value Indy and CrossSocket return, because middleware that consumes `RemoteAddr` (rate limiters, audit loggers, IP-restricted routes) needs a stable non-empty string for loopback in dev/test environments. Flipping the flag delivers that consistency.

### Side effect — this is a process-global change

`RemoteIPLocalHostAsVoidInServers` is read by `TCrtSocket.AcceptRequest` (`mormot.net.sock.pas` line ~6505) on **every** mORMot socket in the process — not just the ones owned by `Horse.Provider.Mormot`. If a single process embeds both this provider **and** another mORMot-based HTTP server (e.g. a `TRestHttpServer` SOA endpoint, an admin port served by `THttpServerSocketGeneric`, a `TWebSocketServer`), that second server will also see `127.0.0.1` in its `RemoteIP` instead of the mORMot-default `''`.

In practice this is what you want — consistent peer IPs are easier to reason about across components, and most middleware ends up writing `if RemoteIP <> '' then …` anyway, which works identically either way.

### When this side effect could surprise you

The one failure mode worth flagging: any code path inside mORMot that compares `RemoteIP = ''` as a loopback shortcut is now disabled. Two known places this can matter:

- **`hsoBan40xIP` option on `THttpServer`** — the ban list will now happily ban `127.0.0.1` if a local test client triggers enough 4xx responses. Mostly harmless in production (loopback is rarely banworthy) but can confuse debugging.
- **`THttpServerGeneric.OnBeforeBody` callbacks** that explicitly want to short-circuit loopback — those will now run their normal path for `127.0.0.1`. If any are present in the same process, they'll need an explicit `if RemoteIP = '127.0.0.1' then` check rather than relying on the empty-string convention.

Neither is a correctness bug; both are behavioural drifts to be aware of when interoperating with non-Horse mORMot code in the same binary.

### Why `initialization`, not inside `Listen`

The flag is a process-global, not a per-server setting. Two options were considered:

| Where to set it | Why rejected |
|---|---|
| Inside `THorseProviderMormot.Listen` before `THttpServer.Create` | Means the flag is at its mORMot-default during process startup until `Listen` runs — anything that creates a mORMot socket in between (e.g. an OnStart hook, a static health-check) sees the wrong value. Also re-sets harmlessly on every `Listen`. |
| Inside the `THorseProviderMormot` class constructor | Class methods don't have a meaningful "constructor" call site; the class is used as a singleton via class methods. |

`initialization` is the correct semantics: fires exactly once per process at unit load, before any code that might create a mORMot socket can run.

### How to opt back out

If a host application has a strong reason to keep mORMot's default loopback-as-empty behaviour (e.g. an existing log-format contract that depends on empty strings), restore the default explicitly after `Horse.Provider.Mormot` is loaded:

```pascal
uses
  Horse.Provider.Mormot,   // forces our 'False' initialization to run first
  mormot.net.sock;         // for the flag

initialization
  RemoteIPLocalHostAsVoidInServers := True;
```

Pascal's `initialization` sections run in declaration order, so a unit that lists `Horse.Provider.Mormot` first will see our change applied, then its own `initialization` can revert. The consequence: `Req.RawWebRequest.RemoteAddr` will report `''` for loopback connections, and middleware needs to compensate.

---

## IsConsole blocking pattern

```pascal
// InternalListen (Horse.Provider.Mormot)
if IsConsole then
begin
  FRunning := True;
  if not Assigned(FStopEvent) then
    FStopEvent := TEvent.Create(nil, True, False, '');   // manual-reset, unsignalled
  while FRunning do
    FStopEvent.WaitFor(INFINITE);
  FreeAndNil(FStopEvent);
end;
```

**Why `while FRunning do`?** `WaitFor(INFINITE)` on Windows blocks until the event is signalled, then returns — it does not loop. The `while` guard is defensive: if `SetEvent` is called before `WaitFor` (theoretically impossible with the current code flow but worth guarding), `FRunning = False` prevents an eternal block.

**Why not just `ReadLn`?** The `SetConsoleCtrlHandler` / `fpSignal` handlers in the .dpr samples call `THorse.StopListen` which calls `Stop` which signals `FStopEvent`. `ReadLn` would require a separate thread to push a newline character — far more complex.

**VCL / Service / LCL shapes:** `IsConsole = False`, so `InternalListen` returns immediately after `WaitStarted`. The VCL message loop, SCM dispatch loop, or LCL event loop runs in the main thread instead.

---

## Double-start guard (SEC-32)

```pascal
// InternalListen
if Assigned(FServer) then
  Stop;   // full drain before new server starts
```

`Stop` calls `FServer.Free` (joins mORMot threads), waits for `FDrainEvent` if any requests are in flight, then frees `FDrainEvent`. Only after all of this does `InternalListen` create the new `THttpServer`. This means a second `Listen` call is always safe and never leaves orphaned threads.

---

## Drain event lifetime (SEC-30)

`FDrainEvent` is a manual-reset event, initially signalled (`TEvent.Create(nil, True, True, '')`). Lifecycle:

1. Created lazily in `InternalListen` if not assigned.
2. `ResetEvent` when the first request increments `FActiveRequests` from 0 to 1.
3. `SetEvent` when the last request decrements `FActiveRequests` from 1 to 0.
4. `Stop` waits on it (up to `DrainTimeoutMs`) after `FServer.Free` to let any active requests finish.
5. `FreeAndNil(FDrainEvent)` at the end of `Stop`.
6. Next `InternalListen` call creates a fresh one.

The event starts signalled so that a `Stop` with no active requests proceeds immediately without waiting.

---

## COMPAT-1 — RawWebResponse fallback

Some middleware writes to `Res.RawWebResponse.Content` or `.ContentType` instead of (or in addition to) calling `Res.Send` / `Res.ContentType`. COMPAT-1 provides a fallback path in the response bridge:

```
Priority order in WriteBody:
  1. AHorseRes.ContentStream   (set by Res.SendFile / Res.Download)
  2. AHorseRes.BodyText        (set by Res.Send — PATCH-RES-4 shadow field)
  3. AHorseRes.RawWebResponse.Content  (COMPAT-1: written by e.g. horse-jhonson on FPC)
  4. IntToStr(Status)          (status >= 400 with no body: minimal error body)
  5. ''                        (204 No Content, HEAD, etc.)

Priority order in Flush for Content-Type:
  1. AHorseRes.CSContentType   (PATCH-RES-4 shadow field)
  2. AHorseRes.RawWebResponse.ContentType  (COMPAT-1 fallback)
```

Shadow fields always win. COMPAT-1 only fires when the shadow fields are empty.

---

## Context pool and pool Reset safety

The mORMot pool (`Horse.Provider.Mormot.Pool`) is structurally identical to the CrossSocket pool:

- `POOL_MAX_SIZE = 512`, `POOL_WARMUP_SIZE = 32`
- `TCriticalSection` for thread-safe acquire/release
- `Acquire` reuses idle contexts; creates new ones up to the ceiling; blocks+creates beyond (or returns a temporary non-pooled context)
- `Release` calls `Ctx.Reset` which calls `FRequest.Clear + FResponse.Clear`

**`Clear` is the only safe way to reset `FBody`.** Never call `FRequest.Body(nil)` — the `Body(AObject)` setter calls `FBody.Free` before assigning, which on CrossSocket would double-free the transport's stream. On the mORMot path `FBody` is always nil so `Body(nil)` is a no-op, but the call is still wrong by convention and dangerous if the code is ever mixed.

---

## Header parsing performance note

`TMormotRawRequest.GetFieldByName` performs a **linear scan** through the entire `InHeaders` string for each call. For routes that call `Req.RawWebRequest.GetFieldByName` multiple times, this O(n×m) cost can add up.

The `TMormotRequestBridge.Populate` method parses headers once into the `THorseRequest.FHeaders` dictionary during request setup. Middleware should prefer `Req.Headers['X-My-Header']` (dictionary O(1) lookup) over `Req.RawWebRequest.GetFieldByName('X-My-Header')` (linear scan) whenever possible.

---

## http.sys backend — `mskHttpApi` (Windows only)

`THttpApiServer` (http.sys, kernel-mode) is the **third** backend, selected by
`THorseMormotConfig.ServerKind = mskHttpApi`. Unlike the two socket servers it descends
straight from `THttpServerGeneric` (not `THttpServerSocketGeneric`) and is built differently,
so `InternalListen` handles it in its own `{$IFDEF MSWINDOWS}` branch:

```pascal
LApiServer := THttpApiServer.Create('', nil, nil, '', [], nil, AConfig.ThreadPool);
if LApiServer.AddUrl('', StringToUtf8(IntToStr(APort)), False, '+', True) <> 0 then
  // raise with the netsh urlacl remedy — never bind silently
  ...
FServer := LApiServer;          // FServer is the shared THttpServerGeneric base
...
THttpApiServer(FServer).WaitStarted(10);   // http.sys WaitStarted is function: boolean
```

Key differences from the socket backends, all handled in the provider:
- **Field type.** `FServer` is `THttpServerGeneric` (the only ancestor common to all three).
  `OnRequest` and `Shutdown` are on that base; **`WaitStarted` is not** (its signature differs
  per family), so it is called per-branch on the concrete type.
- **Construction.** Different constructor (`QueueName`-first, no port arg) plus an `AddUrl`
  call that registers `http://+:<port>/`. `'+'` is the strong wildcard (all host names).
- **URL ACL / rights.** `AddUrl(..., aRegisterUri := True)` asks http.sys to add the
  reservation, which needs Administrator rights **or** a one-time
  `netsh http add urlacl url=http://+:<port>/ user=<account>`. `AddUrl` returns an error code
  (it does not raise), so the provider checks it and raises with that remedy — it never binds
  silently and drops requests.
- **Windows-only.** `THttpApiServer` is `{$ifdef USEWININET}` in mORMot, so every reference is
  inside `{$IFDEF MSWINDOWS}`. Selecting `mskHttpApi` on a non-Windows build raises at `Listen`.
- **`ThreadPool`** sizes the http.sys API processing threads.

`TMormotHandler`, the request/response bridges, and the pool are **unchanged** — http.sys
delivers the same `THttpServerRequestAbstract` to `OnRequest` as the socket servers.

Compile-time default: `HORSE_MORMOT_HTTPAPI` (Windows) in `THorseMormotConfig.Default`,
taking precedence over `HORSE_MORMOT_ASYNC`. Runtime `Cfg.ServerKind := mskHttpApi` always wins.

Consider http.sys when:
- Deploying as a Windows Service alongside IIS (port sharing via http.sys URL reservation)
- You want kernel-mode TLS termination managed by Windows, not the Delphi process
- You want GZIP / kernel response caching offloaded to http.sys

---

## Security header ordering

`BuildHeaders` always writes security defaults **first**, then app headers:

```
X-Content-Type-Options: nosniff         ← always
X-Frame-Options: DENY                   ← always
Referrer-Policy: strict-origin-when-cross-origin  ← always
Cache-Control: no-store                 ← always
Server: <banner>                        ← always

<app CustomHeaders>                     ← from Res.AddHeader
<COMPAT-1 RawWebResponse.CustomHeaders> ← from Res.RawWebResponse.SetCustomHeader
```

If the app sets a header that conflicts with a security default (e.g. `Res.AddHeader('Cache-Control', 'max-age=3600')`), both appear. HTTP clients use the last occurrence for most headers. To replace a security default the response bridge's `BuildHeaders` method must be modified — there is currently no config override path for individual security headers.

---

## Dual-compilation checklist

Every file in `src/` carries `{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}` at the top. When adding or modifying a unit:

| What | Delphi | FPC |
|---|---|---|
| Uses | `System.SysUtils`, `System.Classes`, `System.SyncObjs`, `Web.HTTPApp`, `System.Generics.Collections` | `SysUtils`, `Classes`, `SyncObjs`, `fpHTTP`, `HTTPDefs`, `Generics.Collections` |
| Dictionary iteration | `for Pair in Dict do` | `for I := 0 to Dict.Count - 1 do Names[I] / ValueFromIndex[I]` |
| `TDictionary<K,V>` | `System.Generics.Collections` | `Generics.Collections` |
| `TWebRequest` / `TWebResponse` | `Web.HTTPApp` | `HTTPDefs` — types are `TRequest` / `TResponse` |
| `GetContentLength` return type | `Int64` (Delphi 10.2+) or `Integer` (XE7) | `Integer` always |
| Anonymous procedures | Supported | Supported in FPC 3.2+ `{$MODE DELPHI}` |
| `TNextProc` (middleware 3rd param) | `TNextProc` is an anonymous-proc type — same as `TProc` | `TNextProc = procedure of object` ≠ `TProc = procedure` — always use `TNextProc` explicitly, never `TProc`, in middleware parameter lists |
| Inline `var` | Delphi 10.3+ | Not supported — use `var` block |
| FPC version required | N/A | FPC **3.2.0+** (stable, Lazarus 2.2+) — **no trunk needed** (unlike CrossSocket which requires FPC 3.3.1 for `{$MODESWITCH FUNCTIONREFERENCES}`) |
| LazUtils package | Not needed | Must be added to project's Required Packages — mORMot2's Lazarus package depends on it (`Cannot find Masks` otherwise) |
