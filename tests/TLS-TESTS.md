# mORMot TLS / mutual-TLS integration test

Proves the mORMot provider serves **HTTPS** and enforces **mutual TLS**.

> **New provider capability.** TLS was added to the mORMot provider for these
> tests — `THorseMormotConfig` gained `SSLEnabled`, `SSLCertFile`,
> `SSLPrivKeyFile`, `SSLPassPhrase`, `SSLCACertFile`, `SSLVerifyPeer`,
> `SSLCipherList`, and `InternalListen` now builds a mORMot `TNetTlsContext` and
> passes it to `THttpServerSocketGeneric.WaitStarted(sec, @tls)`.

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

Set `HORSE_PROVIDER_MORMOT` in each project's Conditional Defines, plus the
mORMot2 search paths / static blobs (same as the param tests). The client needs
`Delphi-Cross-Socket` on the search path (`TCrossHttpClient` is the HTTPS driver,
exactly as in the mORMot param test client). OpenSSL must be present at runtime.

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
