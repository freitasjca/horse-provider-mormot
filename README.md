# horse-provider-mormot

mORMot2 transport provider for the [Horse](https://github.com/HashLoad/horse) web framework. Replaces Indy's blocking-thread-per-connection model with **[mORMot2](https://github.com/synopse/mORMot2)**'s HTTP server stack — kernel-level async I/O (IOCP on Windows, epoll on Linux). Three interchangeable backends selectable via `THorseMormotConfig.ServerKind`: `THttpServer` (thread-pool, default), `THttpAsyncServer` (non-blocking event loop), and `THttpApiServer` (Windows http.sys kernel-mode) — see [Server backend](#server-backend--thread-pool--async--httpsys). Hybrid-interface architecture (`IHorseRawRequest` / `IHorseRawResponse`) so every Horse middleware works unchanged.

## Status

> **Working provider, released.** Currently **v1.0.17**. Requests, cookies, multipart,
> `SendFile`/`Download`, `Req.RawWebRequest`/`Res.RawWebResponse`, TLS/mTLS and graceful
> shutdown all work; the integration suite runs 131/131 on Delphi / Windows on both socket
> backends (thread pool and async) with a current mORMot2. The http.sys backend has limits
> of its own: see [http.sys backend limitations](#httpsys-backend-limitations).
>
> The design blueprint is still worth reading before changing the bridges:
> [`doc/building-a-mormot-provider.md`](https://github.com/freitasjca/horse-provider-mormot/blob/master/doc/building-a-mormot-provider.md).
>
> Two things to know before adopting it: TLS was silently serving **plain TCP** until
> v1.0.9 (FIX-MORMOT-TLS-1 — `hsoEnableTls` must be passed to the server *constructor*),
> so use v1.0.9 or later for HTTPS; and on the http.sys backend (`mskHttpApi`) graceful
> shutdown lost the in-flight reply on **every** run until v1.0.12 (FIX-MORMOT-GRACEFUL-2),
> so use v1.0.12 or later there. See [Graceful shutdown](#graceful-shutdown).

## Activation

```pascal
{$DEFINE HORSE_PROVIDER_MORMOT}   // canonical (PATCH-HORSE-2 namespace)

uses
  Horse;

begin
  THorse.Get('/ping', procedure (Req: THorseRequest; Res: THorseResponse)
  begin
    Res.Send('pong');
  end);
  THorse.Listen(9000);
end.
```

`HORSE_PROVIDER_MORMOT` is supported by the PATCH-HORSE-2 three-axis define model, included in [HashLoad/horse ≥ 3.3.0](https://github.com/HashLoad/horse). No legacy alias.

## Server backend — thread-pool / async / http.sys

The provider can host any of mORMot2's HTTP servers. All share the same request handler, so
routing, middleware, the context pool and the request/response bridge are identical — only
the server engine differs:

| `ServerKind` | mORMot class | Model | Platform |
|---|---|---|---|
| `mskThreadPool` *(default)* | `THttpServer` | Socket thread-pool — one thread per concurrent request | All |
| `mskAsync` | `THttpAsyncServer` | Non-blocking event loop (IOCP / epoll / kqueue) — scales past thread-per-request | All |
| `mskHttpApi` | `THttpApiServer` | Windows **http.sys** kernel-mode HTTP — port-sharing, URL ACLs | **Windows only** |

`mskThreadPool`/`mskAsync` descend from `THttpServerSocketGeneric`; `mskHttpApi` descends from
`THttpServerGeneric` and is built differently (the provider calls `AddUrl` to register
`http://+:<port>/`). Selecting `mskHttpApi` on a non-Windows build raises at `Listen`.

> **http.sys URL registration.** `mskHttpApi` registers the listening prefix with http.sys,
> which needs **Administrator rights**, or a one-time per-port reservation:
> `netsh http add urlacl url=http://+:<port>/ user=<account>`. If registration fails the
> provider raises at `Listen` with this exact remedy in the message (it never binds silently).

**Default:** with no config and no define, the provider uses `mskThreadPool` (`THttpServer`) —
unchanged from earlier releases. Two ways to switch backend (async shown; `mskHttpApi` is identical):

```pascal
// 1. Runtime (preferred) — explicit, no build-config dependency:
var
  Cfg: THorseMormotConfig;
begin
  Cfg := THorseMormotConfig.Default;
  Cfg.ServerKind := mskAsync;          // → THttpAsyncServer
  THorse.ListenWithConfig(9000, Cfg);
end;

// 2. Compile-time default — a provider-internal option define, set PROJECT-WIDE
//    (Delphi: Project ▸ Options ▸ Conditional defines; FPC/Lazarus: -dHORSE_MORMOT_ASYNC).
//    A bare {$DEFINE} in the .dpr/.lpr is NOT seen by the Config unit.
{$DEFINE HORSE_MORMOT_ASYNC}           // sibling of HORSE_MORMOT_TRACE
// then a plain THorse.Listen(9000); uses THttpAsyncServer by default.
```

> **`ThreadPool` changes meaning in async mode.** For `mskThreadPool` it is the number of
> concurrent request slots; for `mskAsync` it sizes the async R/W event-loop threads (think
> CPU cores, not client count). An explicit `ServerKind` on the config always wins over the
> define.

Mental model (mirrors the define tiers in `Horse.pas`):

```
HORSE_PROVIDER_MORMOT      ← selects the mORMot transport (axis A)
  HORSE_MORMOT_ASYNC       ← option: use THttpAsyncServer instead of THttpServer
  HORSE_MORMOT_HTTPAPI     ← option (Windows): use http.sys THttpApiServer
  HORSE_MORMOT_TRACE       ← option: emit lifecycle trace
```

Define precedence in `THorseMormotConfig.Default`: `HORSE_MORMOT_HTTPAPI` (Windows) →
`HORSE_MORMOT_ASYNC` → thread-pool. A runtime `Cfg.ServerKind` always overrides the define.

### Integration results per backend

The same 131-check integration suite (`samples/tests`) on each backend, 2026-10-08,
Windows / Delphi 12, provider v1.0.16 + the W1057 cleanup, mORMot2 2.4.17465, test client
built against Delphi-Cross-Socket 1.0.16:

| Backend | Result | What fails |
|---|---|---|
| `mskThreadPool` | **131/131** | — |
| `mskAsync` | **131/131** | — (before mORMot2 2.4.17421, `RemoteAddr` was empty for a loopback client: [mORMot2#639](https://github.com/synopse/mORMot2/issues/639), now fixed) |
| `mskHttpApi` | **131/131** | — (with a test client built against Delphi-Cross-Socket 1.0.15 or older it is 127/131: tests 04 and 15 send an empty `PUT`/`POST` without `Content-Length`, and http.sys answers `411` itself. DCS 1.0.16 sends `Content-Length: 0`, [winddriver#208](https://github.com/winddriver/Delphi-Cross-Socket/pull/208). Any client of yours that omits the header still gets that `411`: see below) |

### Request body size limit

`THorseMormotConfig.MaxBodyBytes` (default 4 MB) is handed to mORMot2's own
`MaximumAllowedContentLength` since v1.0.16, on every backend. An oversized body is
refused with `413` by mORMot2 from its `Content-Length` header, **before** it is read
(a chunked one once it passes the limit). Earlier versions buffered the whole body first and
only then refused it, so an upload cost its full size in memory either way. The
provider's own check stays behind it as a second line. `MaxBodyBytes := 0` means no limit.

### Streaming is not supported

This provider has no streaming engine: `Res.SendStream` (chunked responses, SSE) answers
**`501 Not Implemented`** with a JSON error, on every backend. Send the whole body with
`Res.Send`, or use a provider that streams (CrossSocket, nghttp2).

Before v1.0.15, `Res.SendStream` fell back to Horse's WebBroker stream writer, which
cannot reach the socket through this provider. The client got `200` with an **empty
body** and no error, while the route believed it had streamed. Integration test 47
gates the refusal.

### http.sys backend limitations

These come from mORMot2's http.sys binding (`THttpApiServer`) or from http.sys itself, not
from this provider. Two were fixed in mORMot2 after being reported
([#637](https://github.com/synopse/mORMot2/issues/637) chunked bodies,
[#638](https://github.com/synopse/mORMot2/issues/638) `Set-Cookie`), so **use mORMot2
2.4.17465 or later** with this backend (it also has the #642 and #643 fixes). Prefer `mskThreadPool` or `mskAsync` if any of the
rest matters to you.

- **Chunked request bodies**, by mORMot2 version:
  - **2.4.17428 and later:** delivered, with the default `MaxBodyBytes` (4 MB).
    On 2.4.17428 to 2.4.17463 only, `MaxBodyBytes := 0` makes mORMot2 refuse **every**
    chunked body with `413`: its new chunked loop compared against a zero limit
    ([mORMot2#642](https://github.com/synopse/mORMot2/issues/642), fixed in 2.4.17464).
  - **Earlier:** mORMot2 read a body only when `Content-Length` was present, so a chunked
    body reached the route **empty, with no error**. The provider refuses those with
    `411 Length Required` (since v1.0.13) rather than run the route without its body.
- **Two `Set-Cookie` headers**: both are sent from mORMot2 2.4.17423. Earlier, http.sys kept
  one slot per known header and only the last cookie arrived.
- **Before mORMot2 2.4.17465, an oversized upload stalled its keep-alive connection.**
  mORMot2 answered the `413` without reading the rest of the body or closing the
  connection. curl aborts the upload and reconnects, so it was unaffected; a client that
  finished sending and reused the connection waited on its next request until it timed
  out. Other connections were served normally. From 2.4.17465 http.sys closes the
  connection whenever a request is cut short
  ([mORMot2#643](https://github.com/synopse/mORMot2/issues/643)).
- **`POST`/`PUT` with no body and no `Content-Length` get `411` from http.sys itself**,
  before the request reaches Horse. Send `Content-Length: 0`.
- **No TLS fields**: `SSLEnabled` raises at `Listen`; bind the certificate with
  `netsh http add sslcert`.

Every test server in `tests/` and `samples/tests/` takes the backend from
`HORSE_MORMOT_TEST_BACKEND` (`threadpool`, `async` or `httpapi`); see `tests/TLS-TESTS.md`.

## Minimum requirements

| Component | Minimum | Notes |
|---|---|---|
| **Delphi** | 10.4 Sydney | `inline var`, `System.Threading` — same baseline as Horse. |
| **Lazarus / FPC** | **3.2.0** | Unlike the CrossSocket provider (which needs FPC **3.3.1 trunk** for `{$MODESWITCH FUNCTIONREFERENCES}`), mORMot2 has no such requirement. FPC **3.2.2 stable + Lazarus 2.2+** work out of the box. See [Lazarus / FPC IDE setup](#lazarus--fpc-ide-setup) below. |
| **mORMot2** | latest; **2.4.17465+ for http.sys** | Core units: `mormot.core.base`, `mormot.core.unicode`, `mormot.net.http`, `mormot.net.server`. Validated on 2.4.17458. TLS 1.3 suites need 2.4.16916+; http.sys chunked bodies 2.4.17428+ (2.4.17464+ with `MaxBodyBytes := 0`), http.sys disconnect after an early refusal 2.4.17465+. mORMot2 is not a Boss dependency, so no floor is enforced. |
| **Horse** | ≥ 3.3.10 | 3.3.0 first carried the `HORSE_PROVIDER_*` namespace (PATCH-HORSE-2). The floor is **3.3.10 from provider v1.0.10**, because `StopListenGraceful` is silently inert through `THorse` on anything earlier — see [Graceful shutdown](#graceful-shutdown). |
| **OpenSSL** | 1.1.x or 3.x | *Only if HTTPS is enabled.* |

### mORMot2 static blobs

Static-blob folder required on every target — download `mormot2static.7z` from the latest [mORMot2 GitHub release](https://github.com/synopse/mORMot2/releases/latest) (or `https://synopse.info/files/mormot2static.7z`) and extract into `mORMot2/static/`:

| Build target | Static path |
|---|---|
| **Delphi / Windows** | `mORMot2\static\delphi` — precompiled `.obj` files |
| **Delphi / Linux64** | `mORMot2/static/delphi-linux64` — precompiled `.o` files |
| **FPC (any platform)** | Add `-Fl<path>` pointing at `mORMot2/static/$(TargetCPU)-$(TargetOS)` — e.g. `static/x86_64-win64`, `static/x86_64-linux`, `static/aarch64-linux` |

See [samples/tests/README.md → "Building each project"](samples/tests/README.md#delphi-console--vcl--winservice--linuxdaemon) for the full search-path list with absolute paths.

### OpenSSL *(only if HTTPS is enabled)*

mORMot2 dynamically loads `libssl` / `libcrypto` at startup, OR statically links via the `mormot2static` bundle (preferred for self-contained deployments). Both 1.1.x and 3.x ABIs are accepted.

- **Linux dynamic:** `apt install libssl3 libcrypto3` (Debian/Ubuntu 22.04+, RHEL 9+) or `libssl1.1` (Ubuntu 20.04).
- **Windows dynamic:** ship `libssl-3-x64.dll` + `libcrypto-3-x64.dll` (or the 1.1.x equivalents) next to the `.exe` — not in `System32`.
- **Static link:** preferred for Docker / air-gapped — use the OpenSSL `.o`/`.obj` shipped inside `mormot2static` and reference them via the same search-path that brings in zlib/sqlite.

### Enabling HTTPS / TLS

`THorseMormotConfig` carries the TLS surface (mirroring the CrossSocket / ICS
providers). The provider builds a mORMot `TNetTlsContext` from these fields and
passes it to `THttpServerSocketGeneric.WaitStarted(sec, @tls)`:

```pascal
var
  Cfg: THorseMormotConfig;
begin
  Cfg := THorseMormotConfig.Default;
  Cfg.SSLEnabled     := True;
  Cfg.SSLCertFile    := 'server.crt';
  Cfg.SSLPrivKeyFile := 'server.key';
  // mutual TLS (optional):
  Cfg.SSLCACertFile  := 'ca.crt';
  Cfg.SSLVerifyPeer  := True;          // require + verify a client certificate
  THorseProviderMormot.ListenWithConfig(9443, Cfg);
end;
```

- TLS applies to the **socket backends** — `mskThreadPool` (default) and
  `mskAsync`. The `mskHttpApi` (http.sys) backend binds its certificate at the OS
  level (`netsh http add sslcert`), so `SSLEnabled` raises a clear error there.
- `SSLCipherList` sets the cipher rules for **TLS 1.2 and below only**. It has
  no effect on TLS 1.3, which OpenSSL configures separately.
- `SSLCipherSuitesTLS13` sets the **TLS 1.3** suites (v1.0.14): exact IANA names,
  colon-separated, in priority order, e.g.
  `'TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256'`. It needs **mORMot2
  2.4.16916 or later** (2026-09-16), which added `TNetTlsContext.CipherSuites`;
  the provider detects that at compile time. Every name is checked at `Listen`
  against the five RFC 8446 suites, and an unknown or misspelled one makes
  `Listen` raise, naming it, because OpenSSL would silently drop it. A correctly
  spelled suite that your OpenSSL build does not include is still dropped
  silently; mORMot2 offers no way to read the list back. With an **older
  mORMot2**, a non-empty value makes `Listen` raise instead (as in v1.0.11),
  rather than leave TLS 1.3 at the defaults while the configuration says
  otherwise. Empty keeps mORMot2's default suites.
- See [`tests/TLS-TESTS.md`](tests/TLS-TESTS.md) for the one-way + mutual-TLS
  integration test (`HorseMormotTLSTestServer` / `…Client`).

### Lazarus / FPC IDE setup

> **Key difference from the CrossSocket provider:** mORMot2 supports FPC **3.2.0+** and does not need FPC 3.3.1 trunk. FPC 3.2.2 stable (Lazarus 2.2+) is sufficient.

1. **mormot2 package** — open `mORMot2/src/packages/lazarus/mormot2.lpk` in the Lazarus IDE, compile it. Installation is only needed for design-time components; the HTTP server works with Compile only.

2. **LazUtils package** — add `LazUtils` to your project's required packages (Project → Project Inspector → Required Packages → Add → `LazUtils`). mORMot2's Lazarus package lists `LazUtils` as a dependency; omitting it causes a "Cannot find Masks" or similar compile error.

3. **Source search paths** — add to Project Options → Compiler Options → Paths → Other unit files (`-Fu`):
   ```
   <mORMot2>/src
   <mORMot2>/src/core
   <mORMot2>/src/net
   <mORMot2>/src/lib
   <horse>/src
   <horse-provider-mormot>/src
   ```

4. **Static blob linker path** — add to Other linker options (`-Fl`):
   ```
   <mORMot2>/static/$(TargetCPU)-$(TargetOS)
   ```
   On a 64-bit Windows FPC build this resolves to `static/x86_64-win64`; on Linux to `static/x86_64-linux`.

5. **Project define** — add `-dHORSE_PROVIDER_MORMOT` to Project Options → Compiler Options → Custom options.

> **Anonymous procedures in FPC middleware:** FPC 3.2+ in `{$MODE DELPHI}` supports anonymous procedures. The third parameter of a Horse middleware callback must be typed as `TNextProc` (not `TProc`) — the two are distinct types on FPC (`TNextProc = procedure of object`; `TProc = procedure`). Always write:
> ```pascal
> THorse.Use(procedure(Req: THorseRequest; Res: THorseResponse; Next: TNextProc)
>   begin ... Next; end);
> ```

## Graceful shutdown

`StopListenGraceful(ATimeoutMS)` stops accepting new work, waits for requests already in
flight to finish, and **delivers their responses** before tearing the server down. It is
not the same call as `StopListen`, which is abrupt and unchanged.

```pascal
THorse.StopListenGraceful(5000);   // wait up to 5 s for in-flight work
```

Implemented in **provider v1.0.10** (FIX-MORMOT-GRACEFUL-1), completed for http.sys in
**v1.0.12** (FIX-MORMOT-GRACEFUL-2). Measured: 735-752 ms for 700 ms of remaining work.

Verified on **all three backends** (Windows / Delphi 12):

| Backend | Reply delivered |
|---|---|
| `mskThreadPool` | 60/60 (v1.0.12), 20/20 (v1.0.16) |
| `mskAsync` | 60/60 (v1.0.12), 20/20 (v1.0.16) |
| `mskHttpApi` | 60/60 (v1.0.16, mORMot2 2.4.17458); 0/11 before v1.0.12 |

Each test server in `tests/` takes the backend from `HORSE_MORMOT_TEST_BACKEND`
(`threadpool`, `async` or `httpapi`), so any gate can be repeated per backend without a
rebuild; see `tests/TLS-TESTS.md`.

This provider performs **all three** steps the framework asks for — stop accepting,
drain, tear down — because `THttpServerGeneric.Shutdown` sets a flag without closing a
single socket. After it, `Request()` answers **404 to new requests** while in-flight ones
keep their thread and socket. (The 404 is mORMot's own choice; 503 would be better and
would have to come from Horse's pipeline.)

### What was wrong on http.sys before v1.0.12

The drain counted a request as finished when Horse's pipeline returned, which is
inside mORMot's `OnRequest`, **before** mORMot sends the reply. On the socket backends
that gap is harmless, because their destructors join the worker threads before closing
anything. `THttpApiServer`'s teardown is the other way round: it closes the http.sys
request queue first, which aborts a response still being sent. So on `mskHttpApi` the
drain finished on time (~700 ms) and the client then got WinHTTP error 12030 on every run.

v1.0.12 also waits for mORMot's own `CurrentProcess` count, which every backend
decrements only **after** the send, bounded by the same caller timeout. A 100 ms settle on
the old code also delivered 20/20, which confirmed the cause before the fix was tested.

That was not quite enough. `CurrentProcess` drops when `HttpSendHttpResponse` **returns**,
and the kernel can still be transmitting then. On mORMot2 2.4.17458 the reply was lost in
3 of 80 runs, against 0 of 60 with a 100 ms settle. So **v1.0.16 settles 100 ms on
http.sys by default** (FIX-MORMOT-GRACEFUL-3), and 60/60 since. The socket backends keep 0.
The A/B is suggestive rather than conclusive (Fisher's p is about 0.18); the delay costs
100 ms on a graceful stop of this backend only.

### What was wrong before v1.0.10

The provider had no override, so it inherited Horse's abstract base, which **discards the
timeout**. The defect was purely *ordering*: `Stop` freed the server before draining, and
freeing terminates mORMot's thread pool — so the free already blocked until the in-flight
handler returned, and the handler then had no server left to answer through. The reply
died at the moment the handler *finished*, not when shutdown began. The time was never
wrong; the order was.

**No settle delay is needed on the socket backends, and that was measured rather than
assumed:** an A/B of 60 runs with a 0 ms settle against 60 with 100 ms came back 60/60 both
ways, so their default stays at 0 (http.sys is the exception, above).
`HORSE_MORMOT_SETTLE_MS` overrides the default on every backend.

### The one unexplained loss (v1.0.10)

On v1.0.10 the thread-pool backend delivered the reply in **79 of 80** runs. The single
loss is unexplained: elapsed was normal at 749 ms, so the drain timing was right, and the
reply still did not arrive. It has not recurred in 60 runs on v1.0.12. FIX-MORMOT-GRACEFUL-2
closes a gap of the same shape (counter at zero before the send), but that this was the
cause is **not proven**. A 1-in-80 event can miss 60 runs by chance (about 47%), so treat it
as open.

`tests/run-drain-batch.bat [RUNS] [SETTLE_MS]` is the detector: it counts pass/fail/void
and saves each failing run as `fail-N.log`, because an intermittent is only diagnosable
from the output of the run that failed.

> **Requires Horse >= 3.3.10.** On earlier releases `THorseInstance.StopListenGraceful`
> called its own `StopListen` and bypassed every provider override, so this works only
> when called directly on `THorseProviderMormot` — through `THorse` it is silently inert,
> with no error. Fixed upstream in
> [HashLoad/horse#590](https://github.com/HashLoad/horse/pull/590), released in 3.3.10.

### VCL form and Windows service

Both shapes start through `THorse.Listen`, so **`HORSE_PROVIDER_MORMOT` must be a
project-level define** (Project ▸ Options ▸ Conditional defines, all configurations, then
**Build**). Naming `Horse.Provider.Mormot.VCL` or `.Daemon` in `uses` is not enough:
without the define `THorse` is Horse's default provider and the app serves on Indy.
To confirm the transport, `curl -sI` a route: this provider answers with
`Server: unknown` and `X-Frame-Options: DENY`, Indy with neither.

- **VCL** — descend your main form from `TfrmHorseMormotVCLHost`
  (`Horse.Provider.Mormot.VCL`); it listens on `FormCreate` and stops on `FormClose`.
  The base form has no `.dfm`, so your form's `.dfm` must start with `object`, not
  `inherited` (otherwise the IDE reports *Ancestor for 'TfrmHorseMormotVCLHost' not
  found*).
- **Windows service** — descend your service from `THorseMormotService`
  (`Horse.Provider.Mormot.Daemon`) and register routes in its `OnCreate`. Since v1.0.17
  the base class implements `GetServiceController` (SVC-CTRL-2). Before that, a
  service that did not declare the override itself died at every `sc start` with SCM
  error 1067, and nothing was logged. One service per process.

Measured 2026-10-09 (Windows / Delphi 12, Win64, thread pool, the `samples/tests`
VCL and WinService servers): **131/131 each**. The service ran under the SCM, and
`sc stop` drained and released the port. The Linux daemon, Lazarus LCL and FPC
HTTPApplication shapes have **no recorded run yet**.

---

## Layout

```
src/
├── Horse.Provider.Mormot.pas              Entry point — owns the server (THttpServer/THttpAsyncServer), ExecutePipeline, SendError
├── Horse.Provider.Mormot.Config.pas       THorseMormotConfig record (ServerKind, ThreadPool, MaxBodyBytes, …)
├── Horse.Provider.Mormot.Pool.pas         Pre-allocated THorseContext pool
├── Horse.Provider.Mormot.Request.pas      TMormotRequestBridge — Validate + Populate
├── Horse.Provider.Mormot.Response.pas     TMormotResponseBridge.Flush
├── Horse.Provider.Mormot.RawRequest.pas   TMormotRawRequest implements IHorseRawRequest
├── Horse.Provider.Mormot.RawResponse.pas  TMormotRawResponse implements IHorseRawResponse
├── Horse.Provider.Mormot.WebRequestAdapter.pas   TMormotWebRequest  (thin subclass)
├── Horse.Provider.Mormot.WebResponseAdapter.pas  TMormotWebResponse (thin subclass)
├── Horse.Provider.Mormot.VCL.pas                  TfrmHorseMormotVCLHost + Delphi VCL marker
├── Horse.Provider.Mormot.Daemon.pas               Delphi cross-platform daemon (Windows TService with GetServiceController / POSIX signals)
├── Horse.Provider.Mormot.FPC.Daemon.pas           FPC Linux daemon (fpSignal handlers)
├── Horse.Provider.Mormot.FPC.LCL.pas              Lazarus LCL host form
└── Horse.Provider.Mormot.FPC.HTTPApplication.pas  FPC HTTPApplication-style runner

samples/
├── Delphi/console/                         Single-route console demo
└── tests/                                  Integration test server (HorseMormotTestServer.dpr)
```

## License

MIT.
