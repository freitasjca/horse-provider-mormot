@echo off
setlocal EnableDelayedExpansion
REM ===========================================================================
REM  run-tls-tests.bat  -  TLS / mutual-TLS integration tests (mORMot provider)
REM
REM  Runs HorseMormotTLSTestServer + HorseMormotTLSTestClient in two passes:
REM    1. one-way TLS  (no argument)   -> T1, T2
REM    2. mutual TLS   (mtls argument) -> T3, T4
REM  then a third pass whose peer is openssl s_client, not our client:
REM    3. TLS 1.3 cipher suites (MORMOT-TLS13-SUITES-2) -> C0..C5: the
REM       configured suite is negotiated, an excluded one refused, TLS 1.2
REM       untouched, and a misspelled or unknown suite stops Listen. Needs
REM       openssl.exe on PATH; without it the pass is VOID, not passed.
REM
REM  Usage:  run-tls-tests.bat            (build first with build-tls-dcc.bat)
REM  Exit code: 0 = all passed, N = N failed assertions, 2 = VOID (nothing ran).
REM
REM  ---------------------------------------------------------------------
REM  A VOID run is NOT a pass, and this script goes out of its way to tell
REM  the two apart. Three specific traps it exists to avoid:
REM
REM  1. taskkill /IM CANNOT kill this server. "HorseMormotTLSTestServer.exe"
REM     is 28 characters and Windows truncates image names at 25, so /IM
REM     matches nothing and reports success. We kill by PID instead.
REM
REM  2. A stale server makes a fresh one look healthy. Windows lets a second
REM     process bind an already-owned port without error, so "port is
REM     LISTENING" proves nothing about WHOSE server answers. This script
REM     requires the port to be FREE before it starts anything, and then
REM     records the PID that actually took it.
REM
REM  3. "All passed" against a dead transport. Until 2026-09-24 this provider
REM     served plain TCP whenever SSLEnabled was set (FIX-MORMOT-TLS-1): the
REM     server logged "Listening on https", every handshake failed, and T4
REM     -- which only asserts "not 200" -- passed anyway. So a green suite was
REM     not evidence TLS worked. We now require the server to report an
REM     OpenSSL backend before the client is allowed to run.
REM
REM  No parenthesised blocks anywhere, and ping rather than timeout for the
REM  wait: same cmd quirks build-tls-dcc.bat documents.
REM  ---------------------------------------------------------------------
REM ===========================================================================

set "HERE=%~dp0"
set "BIN=%HERE%bin"
set "SERVER_EXE=%BIN%\HorseMormotTLSTestServer.exe"
set "CLIENT_EXE=%BIN%\HorseMormotTLSTestClient.exe"
set "TLS_PORT=9201"

REM -- Build first, so the gate owns its inputs ------------------------------
REM  A stale .exe passes exactly as convincingly as a current one, and nothing
REM  in the result says which you ran. That cost four void results on
REM  2026-09-24 across these three suites; one was caught only because code
REM  that had since been DELETED happened to still print a diagnostic line.
REM  Timestamp heuristics can be fooled and are awkward to get right in cmd;
REM  rebuilding costs ~2 seconds and removes the question entirely.
REM
REM  A build failure is VOID, not FAILED: nothing was tested, so reporting a
REM  count of failed assertions would be a lie.
REM
REM  Pass  nobuild  to skip it (prebuilt binaries, or a CI stage that already
REM  built) - then staleness is yours to own again.
if /I "%~1"=="nobuild" goto :skip_build
echo === building (pass "nobuild" to skip) ===
call "%HERE%build-tls-dcc.bat"
if errorlevel 1 goto :build_failed
echo.
:skip_build

REM -- Backend under test (B7). HORSE_MORMOT_TEST_BACKEND = threadpool, async or
REM    httpapi is read by the SERVER (HorseMormotTestBackend.pas); unset keeps
REM    the define-selected default. http.sys takes no TLS fields - the provider
REM    refuses SSLEnabled on it - so this suite does not apply there.
set "BACKEND=%HORSE_MORMOT_TEST_BACKEND%"
if "!BACKEND!"=="" (set "BACKEND_LABEL=default") else (set "BACKEND_LABEL=!BACKEND!")
echo backend: !BACKEND_LABEL!
if /I "!BACKEND!"=="httpapi" goto :httpapi_na

if not exist "%SERVER_EXE%" goto :not_built
if not exist "%CLIENT_EXE%" goto :not_built
if not exist "%BIN%\certs\server.crt" goto :no_certs
if not exist "%BIN%\libcrypto-3-x64.dll" goto :no_openssl

set "VOIDED=0"
set /a TOTAL=0

call :runpass "" "one-way TLS" oneway
set /a TOTAL+=%ERRORLEVEL%
call :runpass "mtls" "mutual TLS" mtls
set /a TOTAL+=%ERRORLEVEL%
call :runsuites
set /a TOTAL+=%ERRORLEVEL%

echo.
echo ===========================================================================
if "%VOIDED%"=="1" goto :report_void
if not "%TOTAL%"=="0" goto :report_fail
echo  ALL PASSED [backend !BACKEND_LABEL!] - one-way TLS, mutual TLS, TLS 1.3 suites C0-C5, TLS backend verified.
echo ===========================================================================
exit /b 0
:report_fail
echo  FAILED - %TOTAL% assertion^(s^). Server logs: %BIN%\tls-*.log
echo ===========================================================================
exit /b %TOTAL%
:report_void
echo  VOID - the suite did not run. This is NOT a pass; see the reason above.
echo ===========================================================================
exit /b 2

REM ---------------------------------------------------------------------------
:runpass
REM  %~1 = argument passed to both programs ("" or "mtls")
REM  %~2 = human label      %~3 = short tag used for the log filename
set "ARG=%~1"
set "LABEL=%~2"
set "LOG=%BIN%\tls-%~3.log"
echo.
echo ===========================================================================
echo  TLS pass: !LABEL!
echo ===========================================================================

REM -- The port must be FREE before we start. If something already holds it we
REM    cannot tell our server's answers from the squatter's, so refuse to run
REM    rather than produce a result that cannot be trusted either way.
set "OWNER="
for /f "tokens=5" %%P in ('netstat -ano 2^>nul ^| findstr ":%TLS_PORT% " ^| findstr /I "LISTENING"') do set "OWNER=%%P"
echo    pre-check: port %TLS_PORT% owner=[!OWNER!]
if not "!OWNER!"=="" goto :port_busy

del /q "!LOG!" >nul 2>&1
pushd "%BIN%"
start "" /B cmd /c ""%SERVER_EXE%" !ARG! > "!LOG!" 2>&1"
popd

set /a TRIES=0
:wait_loop
set "SRVPID="
for /f "tokens=5" %%P in ('netstat -ano 2^>nul ^| findstr ":%TLS_PORT% " ^| findstr /I "LISTENING"') do set "SRVPID=%%P"
if not "!SRVPID!"=="" goto :bound
set /a TRIES+=1
if !TRIES! GEQ 20 goto :no_bind
ping -n 2 127.0.0.1 >nul 2>&1
goto :wait_loop

:bound
echo    server pid !SRVPID! listening on port %TLS_PORT%

REM -- [TLS-OSSLVER-1] Record which OpenSSL runtime served this pass. The
REM    server prints it before binding; a passing run never shows the log,
REM    so echo it here. "OpenSSL 3.x" is not one version - the exe takes the
REM    first libcrypto it finds - and a result is only comparable with the
REM    version beside it. Informational: a missing line does not fail the pass.
set "OSSL="
for /f "delims=" %%L in ('findstr /L /C:"TLS backend:" "!LOG!" 2^>nul') do set "OSSL=%%L"
if "!OSSL!"=="" set "OSSL=OpenSSL: not reported by the server - binary predates TLS-OSSLVER-1?"
echo    !OSSL!

REM -- Refuse to test a transport that is not actually TLS. The server prints
REM    its live backend before binding; no OpenSSL line means it either fell
REM    back or never got that far, and every assertion below would be noise.
findstr /C:"TLS backend: OpenSSL" "!LOG!" >nul 2>&1
if errorlevel 1 goto :no_backend

REM -- And the server must be running the mORMot backend that was asked for.
REM    A binary built before HorseMormotTestBackend existed ignores the variable
REM    and would report a threadpool result as an async one.
if not "!BACKEND!"=="" (
  findstr /I /L /C:"backend: !BACKEND! " "!LOG!" >nul 2>&1
  if errorlevel 1 goto :wrong_backend
)

"%CLIENT_EXE%" !ARG!
set "PASS_EXIT=!ERRORLEVEL!"

REM -- [TLS-CONNCLOSE-CHECK] One-way pass only: raw requests through openssl
REM    s_client, every one with "Connection: close". The test client always
REM    keeps connections alive, so it cannot see a server that drops the
REM    reply when the client asks to close - which the ICS provider did for
REM    empty-body requests (FIX-ICS-CONNCLOSE-1, 2026-10-09).
REM    R0  GET /ping                         - CONTROL: the raw sender works
REM    R1  PUT /nobody, Content-Length: 0    - empty body + Connection: close
REM    R2  POST /echo,  Content-Length: 0    - empty body + Connection: close
if not "!ARG!"=="" goto :raw_done
set "RAWSSL="
for /f "delims=" %%I in ('where openssl.exe 2^>nul') do if not defined RAWSSL set "RAWSSL=%%I"
if not defined RAWSSL goto :raw_noopenssl
call :raw_check R0 raw-get-ping.txt pong "GET /ping (raw control)"
set /a PASS_EXIT+=!ERRORLEVEL!
call :raw_check R1 raw-put-cl0.txt put-ok "PUT, Content-Length: 0, Connection: close"
set /a PASS_EXIT+=!ERRORLEVEL!
call :raw_check R2 raw-post-cl0.txt "HTTP/1.1 200" "POST, Content-Length: 0, Connection: close"
set /a PASS_EXIT+=!ERRORLEVEL!
goto :raw_done
:raw_noopenssl
echo   [VOID] R0-R2 need openssl.exe on PATH - the raw requests were NOT sent.
set "VOIDED=1"
:raw_done

taskkill /PID !SRVPID! /F /T >nul 2>&1
exit /b !PASS_EXIT!

REM raw_check <id> <request file> <text the response must contain> <label>
REM  -quiet implies -ign_eof: s_client keeps reading after stdin ends, and the
REM  request's Connection: close makes the server end the session.
:raw_check
"!RAWSSL!" s_client -quiet -connect 127.0.0.1:%TLS_PORT% < "%HERE%%~2" > "%BIN%\raw-%~1.log" 2>&1
findstr /L /C:"%~3" "%BIN%\raw-%~1.log" >nul 2>&1
if errorlevel 1 goto :raw_fail
echo   PASS  %~1 %~4 -^> %~3
exit /b 0
:raw_fail
echo   FAIL  %~1 %~4 - no "%~3" in the response. Response: %BIN%\raw-%~1.log
exit /b 1

:port_busy
echo    [VOID] port %TLS_PORT% is already held by pid !OWNER!.
echo           Windows would let our server bind anyway and the client could
echo           then be testing the OTHER process. Stop it first:
echo             taskkill /PID !OWNER! /F
set "VOIDED=1"
exit /b 0

:no_bind
echo    [VOID] server never bound port %TLS_PORT% within 20 tries.
call :dumplog
set "VOIDED=1"
exit /b 0

:no_backend
echo    [VOID] server never reported an OpenSSL TLS backend.
echo           Rebuild with build-tls-dcc.bat - FORCE_OPENSSL plus
echo           libcrypto-3-x64.dll / libssl-3-x64.dll beside the binary.
call :dumplog
taskkill /PID !SRVPID! /F /T >nul 2>&1
set "VOIDED=1"
exit /b 0

:wrong_backend
echo    [VOID] HORSE_MORMOT_TEST_BACKEND=!BACKEND! but the server did not report
echo           "backend: !BACKEND!". Rebuild - the binary predates the selector.
call :dumplog
taskkill /PID !SRVPID! /F /T >nul 2>&1
set "VOIDED=1"
exit /b 0

:dumplog
echo    ---- server output ----
if exist "!LOG!" type "!LOG!"
echo    -----------------------
exit /b 0

REM ---------------------------------------------------------------------------
REM Pass 3 - TLS 1.3 cipher suites (MORMOT-TLS13-SUITES-2), peer = openssl
REM s_client, not our client. With mORMot2 2.4.16916+ SSLCipherSuitesTLS13 is
REM APPLIED (TNetTlsContext.CipherSuites -> SSL_CTX_set_ciphersuites) after the
REM provider checks every name against the five RFC 8446 suites. Judged by the
REM s_client exit code plus its "Cipher is <suite>" line. C0 is the control: the
REM default server must serve the AES-128-GCM client that the restricted server
REM must refuse in C2. C3: restricting TLS 1.3 leaves TLS 1.2 alone. C4/C5 are
REM startup refusals: a server that comes up is the defect (a typo dropped by
REM OpenSSL, served silently), and the log must name the cause. Mirrors
REM horse-provider-ics pass 4. Built against an OLDER mORMot2 the provider
REM refuses every non-empty value instead (MORMOT-TLS13-SUITES-1), so C1-C3 FAIL
REM there with "never bound" - rebuild against the current mORMot2.
:runsuites
echo.
echo ===========================================================================
echo  TLS pass: TLS 1.3 cipher suites  (openssl s_client peer)
echo ===========================================================================
set "OPENSSL="
for /f "delims=" %%I in ('where openssl.exe 2^>nul') do if not defined OPENSSL set "OPENSSL=%%I"
if not defined OPENSSL goto :cs_noopenssl
set /a CSFAIL=0

call :cs_server "" control13
if "!SRVPID!"=="" goto :cs_end
call :cs_expect "-tls1_3 -ciphersuites TLS_AES_128_GCM_SHA256" ok "Cipher is TLS_AES_128_GCM_SHA256" "C0 control: default server serves a TLS 1.3 AES-128-GCM client"
call :cs_stop

call :cs_server "suites13" suites13
if "!SRVPID!"=="" goto :cs_end
call :cs_expect "-tls1_3 -ciphersuites TLS_CHACHA20_POLY1305_SHA256" ok "Cipher is TLS_CHACHA20_POLY1305_SHA256" "C1 suites13: the configured suite is negotiated"
call :cs_expect "-tls1_3 -ciphersuites TLS_AES_128_GCM_SHA256" refused "" "C2 suites13: an excluded suite is REFUSED"
call :cs_expect "-tls1_2" ok "New, TLSv1.2" "C3 suites13: TLS 1.2 is untouched by the TLS 1.3 setting"
call :cs_stop

call :cs_refusal "suites13typo" suites13typo "TLS_AES_256_GCM_SHA348" "C4 a misspelled suite beside a valid one: Listen refuses, naming it"
call :cs_refusal "suites13bad" suites13bad "TLS_NO_SUCH_SUITE" "C5 no valid suite at all: Listen refuses, naming it"

:cs_end
exit /b !CSFAIL!

:cs_noopenssl
echo    [VOID] openssl.exe is not on PATH - TLS 1.3 suites were NOT
echo           exercised. Add an OpenSSL bin directory to PATH and re-run.
set "VOIDED=1"
exit /b 0

REM cs_server <arg> <logname> - start a server and wait for it to bind.
:cs_server
set "SRVPID="
set "ARG=%~1"
set "LOG=%BIN%\tls-%~2.log"
set "OWNER="
for /f "tokens=5" %%P in ('netstat -ano 2^>nul ^| findstr ":%TLS_PORT% " ^| findstr /I "LISTENING"') do set "OWNER=%%P"
if not "!OWNER!"=="" goto :port_busy
del /q "!LOG!" >nul 2>&1
pushd "%BIN%"
start "" /B cmd /c ""%SERVER_EXE%" !ARG! > "!LOG!" 2>&1"
popd
set /a TRIES=0
:cs_wait
for /f "tokens=5" %%P in ('netstat -ano 2^>nul ^| findstr ":%TLS_PORT% " ^| findstr /I "LISTENING"') do set "SRVPID=%%P"
if not "!SRVPID!"=="" goto :cs_bound
set /a TRIES+=1
if !TRIES! GEQ 20 goto :cs_nobind
ping -n 2 127.0.0.1 >nul 2>&1
goto :cs_wait
:cs_bound
echo    server [%~2] pid !SRVPID! listening on port %TLS_PORT%
exit /b 0
:cs_nobind
echo    FAIL  server [%~2] never bound port %TLS_PORT%
call :dumplog
set /a CSFAIL+=1
exit /b 0

REM cs_stop - kill the server by PID and wait until the port is free again.
:cs_stop
taskkill /PID !SRVPID! /F /T >nul 2>&1
set /a TRIES=0
:cs_stop_wait
set "OWNER="
for /f "tokens=5" %%P in ('netstat -ano 2^>nul ^| findstr ":%TLS_PORT% " ^| findstr /I "LISTENING"') do set "OWNER=%%P"
if "!OWNER!"=="" exit /b 0
set /a TRIES+=1
if !TRIES! GEQ 10 exit /b 0
ping -n 2 127.0.0.1 >nul 2>&1
goto :cs_stop_wait

REM cs_expect <s_client args> <ok|refused> <line expected when ok> <label>
:cs_expect
"!OPENSSL!" s_client -connect 127.0.0.1:%TLS_PORT% %~1 < nul > "%BIN%\suites-s_client.log" 2>&1
set "CSRC=!ERRORLEVEL!"
if /I "%~2"=="ok" goto :cs_expect_ok
if "!CSRC!"=="0" goto :cs_expect_bad
echo    PASS  %~4
exit /b 0
:cs_expect_ok
if not "!CSRC!"=="0" goto :cs_expect_bad
findstr /L /C:"%~3" "%BIN%\suites-s_client.log" >nul 2>&1
if errorlevel 1 goto :cs_expect_bad
echo    PASS  %~4
exit /b 0
:cs_expect_bad
echo    FAIL  %~4  [s_client exit !CSRC!; see %BIN%\suites-s_client.log]
set /a CSFAIL+=1
exit /b 0

REM cs_refusal <arg> <logname> <text the refusal must contain> <label>
REM PASS only when the server never binds AND its log names the cause. A bad
REM HORSE_MORMOT_TEST_BACKEND also stops the server first: that is VOID.
:cs_refusal
set "ARG=%~1"
set "LOG=%BIN%\tls-%~2.log"
set "OWNER="
for /f "tokens=5" %%P in ('netstat -ano 2^>nul ^| findstr ":%TLS_PORT% " ^| findstr /I "LISTENING"') do set "OWNER=%%P"
if not "!OWNER!"=="" goto :port_busy
del /q "!LOG!" >nul 2>&1
pushd "%BIN%"
start "" /B cmd /c ""%SERVER_EXE%" !ARG! > "!LOG!" 2>&1"
popd
set /a TRIES=0
:cs_ref_wait
ping -n 2 127.0.0.1 >nul 2>&1
set "SRVPID="
for /f "tokens=5" %%P in ('netstat -ano 2^>nul ^| findstr ":%TLS_PORT% " ^| findstr /I "LISTENING"') do set "SRVPID=%%P"
if not "!SRVPID!"=="" goto :cs_ref_served
findstr /L /C:"HORSE_MORMOT_TEST_BACKEND=" "!LOG!" >nul 2>&1
if not errorlevel 1 goto :cs_ref_badbackend
findstr /L /C:"%~3" "!LOG!" >nul 2>&1
if not errorlevel 1 goto :cs_ref_ok
set /a TRIES+=1
if !TRIES! GEQ 10 goto :cs_ref_silent
goto :cs_ref_wait
:cs_ref_ok
echo    PASS  %~4
exit /b 0
:cs_ref_served
echo    FAIL  %~4  [the server STARTED - the suite list was accepted]
call :cs_stop
set /a CSFAIL+=1
exit /b 0
:cs_ref_badbackend
echo    [VOID] %~4 - the server refused HORSE_MORMOT_TEST_BACKEND first
call :dumplog
set "VOIDED=1"
exit /b 0
:cs_ref_silent
echo    FAIL  %~4  [no listener, but the log does not contain "%~3"]
call :dumplog
set /a CSFAIL+=1
exit /b 0

:build_failed
echo.
echo ===========================================================================
echo  VOID - the build failed, so nothing was tested. This is NOT a test
echo         failure; fix the build error above and run again.
echo ===========================================================================
exit /b 2
:httpapi_na
echo VOID - this suite does not apply to httpapi: http.sys binds certificates
echo        through netsh, and the provider refuses SSLEnabled on that backend.
echo        Run it with HORSE_MORMOT_TEST_BACKEND unset, threadpool or async.
exit /b 2
:not_built
echo ERROR: the TLS test binaries are not built. Run:
echo          build-tls-dcc.bat
exit /b 2
:no_certs
echo ERROR: %BIN%\certs\server.crt not found - build-tls-dcc.bat copies them.
exit /b 2
:no_openssl
echo ERROR: %BIN%\libcrypto-3-x64.dll not found. Without the OpenSSL runtime
echo        mORMot cannot serve TLS. build-tls-dcc.bat copies both DLLs.
exit /b 2
