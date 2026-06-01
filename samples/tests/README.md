# Integration Test Matrix — `horse-provider-mormot` samples/tests

This tree exercises every supported Provider × Application-type combination using a single shared test client and a per-shape server. The shared client (`HorseCSTestClient.dpr` from `horse-provider-crosssocket/samples/tests/`) is *transport-neutral* — it sends HTTP to `127.0.0.1:9010` and asserts response bodies / headers / status codes. Any of the server projects in this tree can be the target: each registers the same 32 routes via the shared `Horse.Mormot.TestRoutes` unit.

Expected result for every server: **88 passed, 1 failed** (89 sub-assertions). The single failure is the documented multi-value `Set-Cookie` limitation — `FCustomHeaders` is a `TDictionary<string,string>` on Delphi / `TStringList` on FPC, so two `Res.AddHeader('Set-Cookie', …)` calls keep only the last. This is the same result as the CrossSocket provider.

---

## Folder layout

```
samples/tests/
├── README.md                                     ← this file
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

> **Note on defines.** `HORSE_PROVIDER_MORMOT` is reserved in Horse.pas but not yet routed (unlike `HORSE_PROVIDER_CROSSSOCKET` which is fully wired). Until Horse.pas is patched, include `Horse.Provider.Mormot` (and the shape-specific variant) **directly** in the project's `uses` clause — no define is needed. The define column above shows the intended future state.

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

The client (`HorseCSTestClient.dpr` in `horse-provider-crosssocket/samples/tests/`) is transport-neutral. Start any of the server shapes above and then:

```
> HorseCSTestClient.exe
[HorseCSTest] Client - target: http://127.0.0.1:9010
...
[HorseCSTest] 88 passed, 1 failed  (total 89)
```

The single failure is always Test 10 (multi-value `Set-Cookie`) — a Horse core limitation, not a transport or shape bug.

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
# … run HorseCSTestClient from any host that can reach :9010
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
HorseCSTestClient.exe

REM Stop — drains via SEC-30 active-request counter
sc stop HorseMormotTestService

REM Uninstall (elevated)
HorseMormotServiceTestServer.exe /uninstall
```

---

## Why one client, many servers

The point of testing every cross-product combination is to confirm that **transport behaviour is identical** regardless of which Application-type shape wraps it. By keeping:

- **One** route surface (`Common/Horse.Mormot.TestRoutes.pas`)
- **One** client test runner (`HorseCSTestClient.dpr`, shared with CrossSocket)
- **N** per-shape servers — each ~30–50 lines of pure lifecycle wiring

…any divergence in test results between shapes points immediately at a shape-specific bug (in the provider unit), not at a route-surface bug. The `88 passed, 1 failed` baseline is the contract every shape must satisfy.
