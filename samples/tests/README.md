# Integration Test Matrix — `horse-provider-mormot` samples/tests

This tree exercises every supported Provider × Application-type combination using a single test client and a per-shape server. The client (`HorseMormotTestClient.dpr`, in this folder) is *transport-neutral* — it sends HTTP to `127.0.0.1:9010` and asserts response bodies / headers / status codes. Any of the server projects in this tree can be the target: each registers the same routes via the shared `Horse.Mormot.TestRoutes` unit.

**Current baseline: 131 passed, 0 failed on all three backends** (thread pool, async, http.sys) — `HorseMormotTestServer` (Delphi, Console shape) built by `build-tests-dcc.bat`, 2026-10-08, mORMot2 2.4.17458, Horse 3.3.12. http.sys reaches 131 only with a test client built against Delphi-Cross-Socket 1.0.16 or later, which sends `Content-Length: 0` on an empty PUT/POST; with older DCS, http.sys answers tests 04 and 15 with its own 411.

> **Which shapes that baseline covers.** The legacy Console server (row 1) on all three backends, and **row 3 (VCL): 131 passed, 0 failed on 2026-10-09** (Delphi 12, Win64 Release, thread pool, define `HORSE_PROVIDER_MORMOT` only — `HORSE_APPTYPE_VCL` is not needed because the sample names `Horse.Provider.Mormot.VCL` itself; `Server: unknown` + security headers confirmed the transport; port 9010 released when the form closed). **Row 4 (WinService): 131 passed, 0 failed on 2026-10-09** (same toolchain, define `HORSE_PROVIDER_MORMOT`): `sc start` → RUNNING, port 9010 owned by the service PID, `Server: unknown` + security headers, `sc stop` → `MyStop entered` / `THorse.StopListen returned` in 39 ms, port released. It first needed SVC-CTRL-1: the service unit had lost its `GetServiceController` override and died at every start (SCM 1067). No run of rows 2 and 5–7 is recorded. Until 2026-09-04 (commit `6ad5c03`) the WinService sample was wired to the *CrossSocket* service class, and from then until 2026-10-09 it could not compile or start. Treat every other shape as built-from-source-only until someone records a date, toolchain and count here.

---

## Folder layout

```
samples/tests/
├── README.md                                     ← this file
├── HorseMormotTestClient.dpr                     ← the client; targets 127.0.0.1:9010
├── build-tests-dcc.bat                           ← builds server + client with dcc64
├── HorseMormotTestServer.dpr                     ← legacy baseline (Console, direct provider use).
│                                                    Kept for backwards compatibility; same routes
│                                                    as Delphi/Console/ below.
│
├── Common/
│   └── Horse.Mormot.TestRoutes.pas               ← the 32-route surface, dual-compiler.
│                                                    Used by every per-shape server below.
│
├── Delphi/
│   ├── Console/HorseMormotConsoleTestServer.dpr  ← Console shape + SetConsoleCtrlHandler
│   ├── VCL/    HorseMormotVCLTestServer.dpr      ← TfrmHorseMormotVCLHost (non-blocking VCL)
│   │           Main.Form.pas / .dfm
│   ├── WinService/                               ← THorseMormotService (TService base)
│   │   HorseMormotServiceTestServer.dpr
│   │   MyHorseMormotService.pas / .dfm
│   └── LinuxDaemon/                              ← THorseMormotLinuxDaemonApp.Run, target Linux64
│       HorseMormotLinuxDaemonTestServer.dpr
│
└── Lazarus/
    ├── Console/ HorseMormotTestServer.lpr        ← fpSignal + blocking Listen
    └── Daemon/  HorseMormotDaemonTestServer.lpr  ← THorseMormotLinuxDaemonApp.Run
```

---

## Test matrix

| # | Server project | Compiler | App type | Provider unit used | Lifecycle helper | Defines |
|---|---|---|---|---|---|---|
| 1 | `HorseMormotTestServer` *(legacy baseline)* | Delphi | Console | `Horse.Provider.Mormot` | `SetConsoleCtrlHandler` | *(none required)* |
| 2 | `Delphi/Console/HorseMormotConsoleTestServer` | Delphi | Console | `Horse.Provider.Mormot` | `SetConsoleCtrlHandler` | `HORSE_PROVIDER_MORMOT` *(future)* |
| 3 | `Delphi/VCL/HorseMormotVCLTestServer` | Delphi | VCL | `Horse.Provider.Mormot.VCL` | `TfrmHorseMormotVCLHost` | `HORSE_PROVIDER_MORMOT` + `HORSE_APPTYPE_VCL` *(future)* |
| 4 | `Delphi/WinService/HorseMormotServiceTestServer` | Delphi | Service | `Horse.Provider.Mormot.Daemon` | `THorseMormotService` | `HORSE_PROVIDER_MORMOT` + `HORSE_APPTYPE_DAEMON` *(future)* |
| 5 | `Delphi/LinuxDaemon/HorseMormotLinuxDaemonTestServer` | Delphi (Linux64) | Daemon | `Horse.Provider.Mormot.Daemon` | `THorseMormotLinuxDaemonApp.Run` | `HORSE_PROVIDER_MORMOT` + `HORSE_APPTYPE_DAEMON` *(future)* |
| 6 | `Lazarus/Console/HorseMormotTestServer` | FPC | Console | `Horse.Provider.Mormot` | `fpSignal` | `-dHORSE_PROVIDER_MORMOT` *(future)* |
| 7 | `Lazarus/Daemon/HorseMormotDaemonTestServer` | FPC | Daemon | `Horse.Provider.Mormot.Daemon` | `THorseMormotLinuxDaemonApp.Run` | `-dHORSE_PROVIDER_MORMOT` *(future)* |

> **Note on defines.** `HORSE_PROVIDER_MORMOT` is fully routed in `Horse.pas` since Horse 3.3.0 (this provider needs 3.3.12 or later): with it, `+ HORSE_APPTYPE_VCL` selects `Horse.Provider.Mormot.VCL`, `+ HORSE_APPTYPE_DAEMON` selects `Horse.Provider.Mormot.Daemon` (Delphi) or `.FPC.Daemon` (FPC), and on FPC `+ HORSE_APPTYPE_LCL` selects `.FPC.LCL`, with `.FPC.HTTPApplication` as the FPC default. **The define is required, not optional.** Every server here starts through `THorse.Listen`, and `THorse` is whatever provider `Horse.pas` selects; naming `Horse.Provider.Mormot` in `uses` only compiles the unit. Without the define a Delphi build serves on Indy (FPC: fphttpserver) and the client still passes, proving nothing about mORMot. The VCL, WinService and LinuxDaemon `.dpr` files stop the build with a `{$MESSAGE FATAL}` when it is missing (SAMPLE-DEFINE-1, 2026-10-09). Confirm the transport on any run: `curl -sI http://127.0.0.1:9010/ping` must show `Server: unknown` together with `X-Frame-Options: DENY` — the provider's own anti-fingerprinting banner and security headers (`Horse.Provider.Mormot.pas`, `ServerBanner` default `''`); Indy sends neither. Then check `netstat -ano | findstr :9010` names the sample's PID. The *(future)* marks in the table are historical.

> **Rows 4 and 5 share the same defines** for the same reason as CrossSocket: `HORSE_APPTYPE_DAEMON` means "OS-supervised long-running process". `Horse.Provider.Mormot.Daemon.pas` ships both paths in one unit (`{$IFDEF MSWINDOWS}` → `THorseMormotService`; `{$ELSE}` → `THorseMormotLinuxDaemonApp`). The build target, not an extra define, selects the incarnation.

---

## Building each project

### Delphi (Console / VCL / WinService / LinuxDaemon)

1. **File → Open Project** and select the `.dpr` file. Delphi prompts to create the matching `.dproj`; accept.
2. **Project → Options → Application type:** set to the appropriate type — VCL Forms Application for VCL; Service Application for WinService; Console Application for Console / LinuxDaemon (the `.dpr` already has `{$APPTYPE CONSOLE}`).
3. **Project → Options → Delphi Compiler → Search path:** add the following entries. The example below assumes the **standard workspace layout** with all three repos checked out under `C:\lang\Repo\` — `horse-provider-mormot\`, `horse\`, and `mORMot2\` side-by-side. Adjust the drive letter and base path to match your own checkout.

   ```
   C:\lang\Repo\horse-provider-mormot\src      ← this repo
   C:\lang\Repo\horse\src                      ← patched Horse fork
   C:\lang\Repo\mORMot2\src\core               ← mormot.core.*  (RawUtf8, conversions)
   C:\lang\Repo\mORMot2\src\net                ← mormot.net.http, mormot.net.server
   C:\lang\Repo\mORMot2\src\lib                ← mormot.lib.z   (zlib wrapper)
   C:\lang\Repo\mORMot2\src\crypt              ← mormot.crypt.* (pulled in transitively)
   C:\lang\Repo\mORMot2\static\delphi          ← precompiled .obj files (zlib, etc.)
   ```

   Pasted as a single line into the Search path field:
   ```
   C:\lang\Repo\horse-provider-mormot\src;C:\lang\Repo\horse\src;C:\lang\Repo\mORMot2\src\core;C:\lang\Repo\mORMot2\src\net;C:\lang\Repo\mORMot2\src\lib;C:\lang\Repo\mORMot2\static\delphi;C:\lang\Repo\mORMot2\src\crypt
   ```

   Also add `..\..\Common` (relative — points at the shared `Horse.Mormot.TestRoutes.pas` next to the `.dpr`).

   > **`C:\lang\Repo\mORMot2\static\delphi` must exist and contain `.obj` files.** This is *not* in the mORMot2 repo by default — download `mormot2static.7z` from the latest [mORMot2 GitHub release](https://github.com/synopse/mORMot2/releases/latest) (or `https://synopse.info/files/mormot2static.7z`) and extract into `C:\lang\Repo\mORMot2\static\` so you have `C:\lang\Repo\mORMot2\static\delphi\zlibdeflate.obj` etc. Without this folder the build fails with `E1026 File not found: '..\..\static\delphi\zlibdeflate.obj'` and a cascade of `E2065 Unsatisfied forward or external declaration` errors from `mormot.lib.z`.

4. **Project → Build**, then run.

### Lazarus / FPC (Console / Daemon)

1. **Project → New Project**, then add the `.lpr` file. Or **Project → Open Project** on the `.lpr` and let Lazarus generate the `.lpi`.
2. **Compiler Options → Paths → Other unit files:** add (assumes the same `C:\lang\Repo\` workspace as the Delphi section above; on Linux substitute e.g. `/home/me/Repo/`):
   ```
   ..\..\Common
   C:\lang\Repo\horse-provider-mormot\src
   C:\lang\Repo\horse\src
   C:\lang\Repo\mORMot2\src\core
   C:\lang\Repo\mORMot2\src\net
   C:\lang\Repo\mORMot2\src\lib
   C:\lang\Repo\mORMot2\src\crypt
   ```
3. **Compiler Options → Paths → Libraries (-Fl):** add the precompiled static folder for the FPC target:
   ```
   C:\lang\Repo\mORMot2\static\$(TargetCPU)-$(TargetOS)
   ```
   (e.g. resolves to `static\x86_64-win64` on Win64 FPC, `static\x86_64-linux` on Linux64). The static folder must exist — same download as the Delphi note above.
4. **Project → Build**, then run.

---

## Running the shared client

The client (`HorseMormotTestClient.dpr`, in this folder) is transport-neutral. Start any of the server shapes above and then:

```
> HorseMormotTestClient.exe
[HorseMormotTest] Ensure a mORMot2 Horse server is running on port 9010.
...
[HorseMormotTest] 131 passed, 0 failed  (total 131) in … ms wall clock
```

The exit code is the number of failed checks.

---

## Server backend — test both `THttpServer` and `THttpAsyncServer`

The provider hosts one of two mORMot2 socket servers, chosen by
`THorseMormotConfig.ServerKind` (`mskThreadPool` → `THttpServer`, the default;
`mskAsync` → `THttpAsyncServer`). The test servers above use the default
(thread-pool). Because both backends share the same routing, pool and
request/response bridge, the **entire test matrix must pass identically on
both** — so it doubles as the async regression check.

To run the suite against the async backend, pick either:

- **Compile-time:** add `HORSE_MORMOT_ASYNC` to the project's Conditional Defines
  (Delphi: Project ▸ Options; Lazarus: `-dHORSE_MORMOT_ASYNC`) — set it
  **project-wide**, not as a bare `{$DEFINE}` in the `.dpr`/`.lpr`, or the Config
  unit won't see it. Rebuild and re-run the same client.
- **Runtime:** change the test server's `THorse.Listen(TEST_PORT)` to
  ```pascal
  var LCfg := THorseMormotConfig.Default;
  LCfg.ServerKind := mskAsync;
  THorse.ListenWithConfig(TEST_PORT, LCfg);
  ```
  (add `Horse.Provider.Mormot.Config` to `uses`), rebuild and re-run.

**Expected result is identical: 131 passed, 0 failed.** Any delta between the
backends is a real bug in that backend's path, not the suite. The legacy
`HorseMormotTestServer` (row 1) also honours `HORSE_MORMOT_TEST_BACKEND` (`threadpool` | `async` | `httpapi`) at
run time, which needs no rebuild.

> Tip: the bench server (`horse-provider-crosssocket/samples/bench/Servers/Mormot/`)
> already exposes a `--async` switch for the same A/B under load.

---

## Linux daemon: systemd unit template

For shapes 5 (Delphi/LinuxDaemon) and 7 (Lazarus/Daemon):

```ini
# /etc/systemd/system/horsemormot-test-daemon.service
[Unit]
Description=Horse mORMot2 integration test daemon
After=network.target

[Service]
Type=simple
ExecStart=/opt/horsemormot-test/HorseMormotLinuxDaemonTestServer
# or:    /opt/horsemormot-test/HorseMormotDaemonTestServer
Restart=on-failure
RestartSec=2s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```sh
sudo cp horsemormot-test-daemon.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start  horsemormot-test-daemon
sudo systemctl status horsemormot-test-daemon
# … run HorseMormotTestClient from any host that can reach :9010
sudo systemctl stop   horsemormot-test-daemon    # SIGTERM → SEC-30 drain → exit 0
```

---

## Windows Service: install / start / stop

For shape 4 (Delphi/WinService):

```bat
REM Run from an elevated Command Prompt (right-click → Run as administrator)
HorseMormotServiceTestServer.exe /install

REM Start via SCM
sc start HorseMormotTestService

REM Verify
sc query HorseMormotTestService

REM Run the client (any host that can reach :9010)
HorseMormotTestClient.exe

REM Stop — drains via SEC-30 active-request counter
sc stop HorseMormotTestService

REM Uninstall (elevated)
HorseMormotServiceTestServer.exe /uninstall
```

---

## Why one client, many servers

The point of testing every cross-product combination is to confirm that **transport behaviour is identical** regardless of which Application-type shape wraps it. By keeping:

- **One** route surface (`Common/Horse.Mormot.TestRoutes.pas`)
- **One** client test runner (`HorseMormotTestClient.dpr`)
- **N** per-shape servers — each ~30–50 lines of pure lifecycle wiring

…any divergence in test results between shapes points immediately at a shape-specific bug (in the provider unit), not at a route-surface bug. The Console baseline (131 passed, 0 failed) is the contract every shape must satisfy.
