# mORMot TLS / mutual-TLS integration test

Proves the mORMot provider serves **HTTPS** and enforces **mutual TLS**.

> **New provider capability.** TLS was added to the mORMot provider for these
> tests — `THorseMormotConfig` gained `SSLEnabled`, `SSLCertFile`,
> `SSLPrivKeyFile`, `SSLPassPhrase`, `SSLCACertFile`, `SSLVerifyPeer`,
> `SSLCipherList`, and `InternalListen` builds a mORMot `TNetTlsContext`, passes
> it to `THttpServerSocketGeneric.WaitStarted(sec, @tls)`, **and constructs the
> server with `hsoEnableTls`**.
>
> That last part is not optional and is why this suite could not pass before
> 2026-09-24 (FIX-MORMOT-TLS-1). `WaitStarted` begins its TLS setup with
> `if (hsoEnableTls in fOptions) and (TLS <> nil)`, so without the option the
> context is accepted and silently discarded — no exception, no log, and the
> server still reports itself listening on https while serving plain TCP. It has
> to reach the **constructor**: `THttpAsyncServer.Create` translates
> `hsoEnableTls` into its own `acoEnableTls` in the constructor body, so setting
> the `Options` property afterwards would work for `mskThreadPool` and fail
> silently for `mskAsync`.

| File | Role |
|---|---|
| `HorseMormotTLSTestServer.dpr` | HTTPS server on **port 9201**; `GET /ping`, `POST /echo` |
| `HorseMormotTLSTestClient.dpr` | Driver; exit code = number of failed assertions |
| `certs/` | Self-signed fixture PKI (shared with the other providers) |

## Certificates (`certs/`)

Generated once by `certs/gen-certs.sh` (OpenSSL) and committed:

```
ca.crt / ca.key          test CA
server.crt / server.key  server cert — CN/SAN = localhost, 127.0.0.1, ::1
client.crt / client.key  client cert — for mutual TLS
```

**Test-only throwaway keys.** Copy `certs/` next to the built binaries (or run
from this `tests/` folder); both programs locate it via `FindCertDir`.

## Build

```
build-tls-dcc.bat            # Release (default); or: build-tls-dcc.bat Debug
```

Builds both programs, copies `certs/` and the OpenSSL DLLs next to them, and
reports `BUILD OK`. Win64 only; run it from this `tests/` folder.

These two programs have **no `.dproj`**, unlike the param tests beside them, and
msbuild is not a workable substitute on this toolchain — MSBuild's DCC task emits
the IDE's whole global Library Path four times over against a 32000-character
ceiling and dies on MSB6002/MSB6003. The script drives `dcc64` directly, the way
the IDE does.

To build in the IDE instead, the requirements are: `HORSE_PROVIDER_MORMOT` **and
`FORCE_OPENSSL`** in Conditional Defines, the mORMot2 search paths / static blobs
(same as the param tests), and `Delphi-Cross-Socket` on the client's path
(`TCrossHttpClient` is the HTTPS driver, as in the param test client).

> **`FORCE_OPENSSL` is mandatory on Windows.** mORMot resolves its TLS layer by
> whoever assigns `NewNetTls` first, and `mormot.lib.openssl11` claims it
> unconditionally only under this define — otherwise its initialization is
> guarded by `if not Assigned(NewNetTls)`. Adding the unit to `uses` is not
> enough by itself. mORMot's own `tools/mget/mget.dpr` carries the same
> instruction. The server enforces it with a `{$MESSAGE FATAL}` rather than
> letting it fail at runtime.
>
> `libcrypto-3-x64.dll` and `libssl-3-x64.dll` must also sit beside the binary —
> the define picks the backend at compile time, the DLLs have to load at run
> time. `build-tls-dcc.bat` copies both.

The server prints which backend actually loaded before it binds:

```
[MormotTLSTest] TLS backend: OpenSSL OpenSSL 3.5.6 7 Apr 2026
```

It refuses to start if OpenSSL is unavailable. That line separates "wrong TLS
backend" from "right backend, broken configuration" before any client is
involved — check it first when a handshake fails.

> **Backend note.** TLS applies to the socket backends — `mskThreadPool` (default)
> and `mskAsync`. The `mskHttpApi` (http.sys) backend binds its certificate at the
> OS level (`netsh http add sslcert`), so `SSLEnabled` raises a clear error there.
> This test uses the default socket backend.

## Run

**One-way TLS:**

```
HorseMormotTLSTestServer        # terminal 1
HorseMormotTLSTestClient        # terminal 2  → T1, T2 pass
```

**Mutual TLS** — pass `mtls` to **both**:

```
HorseMormotTLSTestServer mtls   # terminal 1
HorseMormotTLSTestClient mtls    # terminal 2  → T3, T4 pass
```

## What each assertion proves

| Mode | Check | Proves |
|---|---|---|
| one-way | T1 `GET /ping` → 200 "pong" | TLS handshake + HTTPS round-trip |
| one-way | T2 `POST /echo` → body echoed | request body survives the TLS path |
| mTLS | T3 `GET /ping` **with** client cert → 200 | `ClientCertificateAuthentication` accepts a CA-signed cert |
| mTLS | T4 `GET /ping` **without** client cert → rejected | mTLS is enforced (peer without cert refused) |

The mTLS client certificate is injected by subclassing `TCrossHttpClient` and
overriding `CreateHttpCli`.

T4 asserts only that the request did **not** return 200, which on its own would
also pass against a server that was simply broken. What makes it meaningful is
the server side: under `HORSE_TRACE=1` a 10-run mtls loop logs exactly 10
`GET /ping` traces, not 20 — T4's request never reaches the pipeline because it
is refused during the handshake.

## Diagnosing a failure

```
set HORSE_TRACE=1
build-tls-dcc.bat
```

Compiles in `HORSE_MORMOT_TRACE`, which prints one line per phase per request on
the **server** console:

```
[trace POST /echo tid=21356] ENTER
[trace POST /echo tid=21356] VALOK
[trace POST /echo tid=21356] ROUTE
[trace POST /echo tid=21356] FLUSHED status=200 body-bytes=9
```

Off by default; `set HORSE_TRACE=` to go back to a clean build.

**A 400 does not tell you where it came from — the body does.** The provider's
own rejections carry `{"error":"..."}` and a `Server:` header. A **400 with an
empty body** was produced by mORMot while parsing, before the pipeline ran, and
means the request never reached Horse at all. A client reporting
`status=400 body=` is the signature of a transport that is not speaking TLS: the
ClientHello gets read as an HTTP request line. Absence of an `ENTER` line
confirms it.

Two further traps, both of which have produced misleading results here:

- **The tests bind `127.0.0.1`.** From WSL that is WSL's own loopback — use the
  Windows host IP (`ip route show | grep default`) or run curl on Windows.
- **Check the server mode before reading a curl failure.** `tlsv13 alert
  certificate required` from a plain `curl -k` means the server is in `mtls`
  mode and is correctly refusing a client that offered no certificate.
