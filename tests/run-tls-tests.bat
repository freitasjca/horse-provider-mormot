@echo off
setlocal EnableDelayedExpansion
REM ===========================================================================
REM  run-tls-tests.bat  -  TLS / mutual-TLS integration tests (mORMot provider)
REM
REM  Runs HorseMormotTLSTestServer + HorseMormotTLSTestClient in two passes:
REM    1. one-way TLS  (no argument)   -> T1, T2
REM    2. mutual TLS   (mtls argument) -> T3, T4
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

echo.
echo ===========================================================================
if "%VOIDED%"=="1" goto :report_void
if not "%TOTAL%"=="0" goto :report_fail
echo  ALL PASSED - one-way TLS and mutual TLS, TLS backend verified.
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

REM -- Refuse to test a transport that is not actually TLS. The server prints
REM    its live backend before binding; no OpenSSL line means it either fell
REM    back or never got that far, and every assertion below would be noise.
findstr /C:"TLS backend: OpenSSL" "!LOG!" >nul 2>&1
if errorlevel 1 goto :no_backend

"%CLIENT_EXE%" !ARG!
set "PASS_EXIT=!ERRORLEVEL!"

taskkill /PID !SRVPID! /F /T >nul 2>&1
exit /b !PASS_EXIT!

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

:dumplog
echo    ---- server output ----
if exist "!LOG!" type "!LOG!"
echo    -----------------------
exit /b 0

:build_failed
echo.
echo ===========================================================================
echo  VOID - the build failed, so nothing was tested. This is NOT a test
echo         failure; fix the build error above and run again.
echo ===========================================================================
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
