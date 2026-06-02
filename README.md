# horse-provider-mormot

mORMot2 transport provider for the [Horse](https://github.com/HashLoad/horse) web framework. Replaces Indy's blocking-thread-per-connection model with **[mORMot2](https://github.com/synopse/mORMot2)**'s `THttpServer` — kernel-level async I/O (IOCP on Windows, epoll on Linux) wrapped around a managed thread pool. `THttpApiServer` (http.sys, Windows kernel-mode) is a drop-in swap requiring no provider changes. Hybrid-interface architecture (`IHorseRawRequest` / `IHorseRawResponse`) so every Horse middleware works unchanged.

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

`HORSE_PROVIDER_MORMOT` is reserved in `patches/horse/src/Horse.pas` (PATCH-HORSE-2 three-axis define model). No legacy alias.

## Minimum requirements

- Delphi 10.4 Sydney or later (inline `var`, `System.Threading`) — same as Horse + mORMot2. FPC 3.2+ supported on the FPC.* shape units.
- mORMot2 (`mormot.core.base`, `mormot.core.unicode`, `mormot.net.http`, `mormot.net.server`). Static-blob folder required on every target:
  - **Delphi / Windows:** `mORMot2\static\delphi` populated with precompiled `.obj` files.
  - **Delphi / Linux64:** `mORMot2/static/delphi-linux64` populated with precompiled `.o` files.
  - **FPC (any platform):** Search-path `-Fl` points at `mORMot2/static/$(TargetCPU)-$(TargetOS)` — resolves to `static/x86_64-win64`, `static/x86_64-linux`, `static/aarch64-linux`, etc., per build target.

  Download `mormot2static.7z` from the latest [mORMot2 GitHub release](https://github.com/synopse/mORMot2/releases/latest) (or `https://synopse.info/files/mormot2static.7z`) and extract into `mORMot2/static/` so every target folder above exists. See [samples/tests/README.md → "Building each project"](samples/tests/README.md#delphi-console--vcl--winservice--linuxdaemon) for the full Search-path list (worked example with absolute paths under `C:\lang\Repo\`).
- **OpenSSL** *(only if HTTPS is enabled)* — mORMot2 dynamically loads `libssl` / `libcrypto` at startup, OR statically links via the `mormot2static` bundle (preferred for self-contained deployments). Both 1.1.x and 3.x ABIs are accepted.
  - **Linux dynamic:** `apt install libssl3 libcrypto3` (Debian/Ubuntu 22.04+, RHEL 9+) or `libssl1.1` (Ubuntu 20.04).
  - **Windows dynamic:** ship `libssl-3-x64.dll` + `libcrypto-3-x64.dll` (or the 1.1.x equivalents) next to the `.exe` — not in `System32`.
  - **Static link:** preferred for Docker / air-gapped — use the OpenSSL `.o`/`.obj` shipped inside `mormot2static` and reference them via the same search-path that brings in zlib/sqlite. See the cross-provider [OpenSSL section in `horse/doc/deployment.md`](https://github.com/HashLoad/horse/blob/master/doc/deployment.md#https--tls-runtime---what-to-ship-per-os) for the full per-OS matrix.
- [Horse](https://github.com/freitasjca/horse) `>= 3.1.98` (the PATCH-HORSE-2 release; older versions lack `HORSE_PROVIDER_*` namespace).

## Layout

```
src/
├── Horse.Provider.Mormot.pas              Entry point — owns THttpServer, ExecutePipeline, SendError
├── Horse.Provider.Mormot.Config.pas       THorseMormotConfig record (ThreadPool, MaxBodyBytes, …)
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
