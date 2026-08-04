# horse-provider-mormot

mORMot2 transport provider for the [Horse](https://github.com/HashLoad/horse) web framework. Replaces Indy's blocking-thread-per-connection model with **[mORMot2](https://github.com/synopse/mORMot2)**'s HTTP server stack — kernel-level async I/O (IOCP on Windows, epoll on Linux). Three interchangeable backends selectable via `THorseMormotConfig.ServerKind`: `THttpServer` (thread-pool, default), `THttpAsyncServer` (non-blocking event loop), and `THttpApiServer` (Windows http.sys kernel-mode) — see [Server backend](#server-backend--thread-pool--async--httpsys). Hybrid-interface architecture (`IHorseRawRequest` / `IHorseRawResponse`) so every Horse middleware works unchanged.

## Status

> **🚧 Under construction.** This repo is a scaffold. Implementation follows the blueprint at [`horse-provider-mormot/doc/building-a-mormot-provider.md`](https://github.com/freitasjca/horse-provider-mormot/blob/master/doc/building-a-mormot-provider.md) — read that first.

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

## Minimum requirements

| Component | Minimum | Notes |
|---|---|---|
| **Delphi** | 10.4 Sydney | `inline var`, `System.Threading` — same baseline as Horse. |
| **Lazarus / FPC** | **3.2.0** | Unlike the CrossSocket provider (which needs FPC **3.3.1 trunk** for `{$MODESWITCH FUNCTIONREFERENCES}`), mORMot2 has no such requirement. FPC **3.2.2 stable + Lazarus 2.2+** work out of the box. See [Lazarus / FPC IDE setup](#lazarus--fpc-ide-setup) below. |
| **mORMot2** | latest | Core units: `mormot.core.base`, `mormot.core.unicode`, `mormot.net.http`, `mormot.net.server`. |
| **Horse** | ≥ 3.3.0 | First official release with `HORSE_PROVIDER_*` namespace (PATCH-HORSE-2) built in. |
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
├── Horse.Provider.Mormot.Daemon.pas               Delphi cross-platform daemon (Windows TService / POSIX signals)
├── Horse.Provider.Mormot.FPC.Daemon.pas           FPC Linux daemon (fpSignal handlers)
├── Horse.Provider.Mormot.FPC.LCL.pas              Lazarus LCL host form
└── Horse.Provider.Mormot.FPC.HTTPApplication.pas  FPC HTTPApplication-style runner

samples/
├── Delphi/console/                         Single-route console demo
└── tests/                                  Integration test server (HorseMormotTestServer.dpr)
```

## License

MIT.
