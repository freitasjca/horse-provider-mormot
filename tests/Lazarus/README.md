# Lazarus / FPC param-test projects — horse-provider-mormot

FPC ports of the Delphi `tests/HorseMormotParamTest{Server,Client}.dpr`
programs. Same routes, same port (**9200**), same test sections **A–I** — so the
FPC client (or the Delphi client) exercises an identical surface.

| File | Role |
|---|---|
| `HorseMormotParamTestServer.lpr` | Console server on port 9200 — run first |
| `HorseMormotParamTestClient.lpr` | Sequential test runner; exit code = number of failures |

## Why these are `.lpr` (and there are no `.lpi` here)

`.lpr` is the FPC program source — the substance of the port. The `.lpi`
(Lazarus project file) is IDE-managed XML carrying *your* machine's unit search
paths, so it is intentionally **not** committed here. Create it once per machine:

> **Project → New Project → Program**, then **Project → Add existing unit** →
> select the `.lpr`. Set the items below, then **Save**.

## Server vs client — the key FPC difference

- **Server** route handlers are plain **unit-scope procedures** registered with
  no `@` (e.g. `THorse.Get('/ping', RoutePing)`). This is the
  `Horse.BenchRoutes.pas` pattern and compiles on stock FPC **without**
  `HORSE_FPC_FUNCTIONREFERENCES`.
- **Client** uses CrossSocket's `TCrossHttpClient` (the client lib, reused
  regardless of which server it talks to). Its callbacks are `reference to
  procedure` and the helpers capture local state, so it **requires an FPC with
  function-reference support** — the same toolchain the shipped
  `horse-provider-crosssocket/samples/bench/Client/Lazarus/HorseBenchClient.lpr`
  targets. If your FPC rejects the anonymous callbacks, run the **Delphi**
  client against this FPC server — the wire surface is identical.

## Required project settings

**Server** — Project Options → Compiler Options → Custom Options:
```
-dHORSE_PROVIDER_MORMOT
```

**Client** — no provider define needed (it is a pure HTTP client and depends
only on the CrossSocket client lib, not on mORMot).

**Both** — add unit search paths (Project Options → Compiler Options → Paths →
*Other unit files*) to:
- `horse/src`
- `mORMot2/src` (+ the mORMot subfolders that repo requires)
- `horse-provider-mormot/src`
- the client also needs `Delphi-Cross-Socket/Source` (for `TCrossHttpClient`)

**Leak detection** — FPC has no `ReportMemoryLeaksOnShutdown`; build the server
with `-gh` (heaptrc) to get a leak report on exit. Stop the server with
Ctrl-C / SIGTERM so `THorse.StopListen` drains in-flight work first, otherwise
heaptrc reports false positives.

## Run sequence (Linux)

```sh
lazbuild HorseMormotParamTestServer.lpi      # after you create the .lpi
lazbuild HorseMormotParamTestClient.lpi
./HorseMormotParamTestServer &               # listens on 9200
./HorseMormotParamTestClient                 # exit code = failures
kill -INT %1                                 # clean shutdown
```
