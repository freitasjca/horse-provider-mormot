@echo off
REM ===========================================================================
REM  build-tls-dcc.bat
REM  Build HorseMormotTLSTestServer / HorseMormotTLSTestClient by invoking
REM  dcc64 DIRECTLY. Run them per TLS-TESTS.md once this reports BUILD OK.
REM
REM  ---------------------------------------------------------------------
REM  Why this script exists
REM
REM  The TLS tests have no .dproj, unlike the param tests beside them. They
REM  were written, documented in TLS-TESTS.md and never committed - the repo
REM  has shipped a description of a suite nobody could run since 2026-06.
REM
REM  And msbuild is not the way to fix that on this machine. Measured in
REM  horse-provider-nghttp2/scripts/build-dcc.bat: MSBuild's DCC task emits
REM  the IDE's entire global Library Path four times over (once each for
REM  -I/-O/-R/-U) against a 32000-character ceiling, so every project dies on
REM  MSB6002/MSB6003 before compiling anything. The IDE is fine because it
REM  drives the compiler directly. So does this.
REM
REM  Flags, unit-path shape and the --no-config decision are lifted from that
REM  script rather than reinvented; --no-config stops dcc64.cfg reintroducing
REM  the machine-wide paths this exists to avoid.
REM
REM  No parenthesised blocks anywhere - same cmd quirk build-dcc.bat documents.
REM  ---------------------------------------------------------------------
REM
REM  Usage:  build-tls-dcc.bat [Release|Debug]      (default Release)
REM  Win64 only. Run from this tests\ folder.
REM ===========================================================================
setlocal enabledelayedexpansion

set "TGTCONFIG=%~1"
if "!TGTCONFIG!"=="" set "TGTCONFIG=Release"
if /I "!TGTCONFIG!"=="Release" goto :cfg_ok
if /I "!TGTCONFIG!"=="Debug"   goto :cfg_ok
echo ERROR: config must be Release or Debug, got "!TGTCONFIG!".
exit /b 2
:cfg_ok

REM -- Locate dcc64 ----------------------------------------------------------
if not "%DELPHI_ROOT%"=="" if exist "%DELPHI_ROOT%\bin\dcc64.exe" set "DCC=%DELPHI_ROOT%\bin\dcc64.exe"
if not defined DCC for %%V in (23.0 22.0 21.0 20.0 19.0) do call :try_version %%V
if not defined DCC for /f "delims=" %%I in ('where dcc64.exe 2^>nul') do if not defined DCC set "DCC=%%I"
if not defined DCC goto :no_dcc

for %%I in ("!DCC!") do set "DCCDIR=%%~dpI"
for %%I in ("!DCCDIR!..") do set "BDSROOT=%%~fI"
set "RTL=!BDSROOT!\lib\Win64\release"
if /I "!TGTCONFIG!"=="Debug" set "RTL=!BDSROOT!\lib\Win64\debug"
if not exist "!RTL!" goto :no_rtl

REM -- Source roots. Same list as HorseMormotParamTestClient.dproj, which is
REM    the neighbouring suite that already builds.
for %%I in ("%~dp0..") do set "PROV=%%~fI"
for %%I in ("!PROV!\..") do set "ROOT=%%~fI"

set "UPATH=!RTL!;!PROV!\src;!ROOT!\horse\src"
set "UPATH=!UPATH!;!ROOT!\mORMot2\src\core;!ROOT!\mORMot2\src\net;!ROOT!\mORMot2\src\lib"
set "UPATH=!UPATH!;!ROOT!\mORMot2\src\crypt;!ROOT!\mORMot2\static\delphi"
set "UPATH=!UPATH!;!ROOT!\Delphi-Cross-Socket;!ROOT!\Delphi-Cross-Socket\Net"
set "UPATH=!UPATH!;!ROOT!\Delphi-Cross-Socket\Utils;!ROOT!\Delphi-Cross-Socket\DelphiToFPC"
set "UPATH=!UPATH!;!ROOT!\Delphi-Cross-Socket\CnPack\Common;!ROOT!\Delphi-Cross-Socket\CnPack\Crypto"

if not exist "!PROV!\src\Horse.Provider.Mormot.Config.pas" goto :no_prov
if not exist "!ROOT!\mORMot2\src\core"                     goto :no_mormot

set "NS=Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win;System;Xml;Data;Datasnap;Web;Soap"
set "ALIAS=Generics.Collections=System.Generics.Collections;Generics.Defaults=System.Generics.Defaults;WinTypes=Winapi.Windows;WinProcs=Winapi.Windows;DbiTypes=BDE;DbiProcs=BDE;DbiErrs=BDE"
REM  FORCE_OPENSSL is not optional on Windows. mORMot resolves its TLS layer by
REM  whoever assigns NewNetTls first, and mormot.net.sock.windows.inc claims it
REM  for SChannel during initialization. mormot.lib.openssl11 only takes over if
REM  FORCE_OPENSSL is defined - otherwise its assignment is guarded by
REM  "if not Assigned(NewNetTls)" and quietly declines. SChannel's server side
REM  wants a .pfx, these tests ship PEM, so without this every handshake fails
REM  while the server still reports itself listening.
set "DEFS=!TGTCONFIG!;HORSE_PROVIDER_MORMOT;FORCE_OPENSSL"
REM  Opt-in request tracing. HORSE_MORMOT_TRACE makes the provider print
REM  ENTER / VALOK / REJECT / FLUSHED / DONE per request on the SERVER console,
REM  which is the only way to tell a rejection by our pipeline from one mORMot
REM  made while parsing - both look like a bare 400 from the client side.
REM    set HORSE_TRACE=1  &  build-tls-dcc.bat
if /I "%HORSE_TRACE%"=="1" set "DEFS=!DEFS!;HORSE_MORMOT_TRACE"
set "OPTS=--no-config -B -Q -TX.exe"
if /I "!TGTCONFIG!"=="Release" set "OPTS=!OPTS! -$D0 -$L- -$Y-"

set "EXEDIR=%~dp0bin"
set "DCUDIR=%~dp0temp"
if not exist "!EXEDIR!" mkdir "!EXEDIR!" 2>nul
if not exist "!DCUDIR!" mkdir "!DCUDIR!" 2>nul

echo dcc64:  !DCC!
echo config: !TGTCONFIG!
echo out:    !EXEDIR!
echo.

set "FAILED=0"
call :build HorseMormotTLSTestServer
call :build HorseMormotTLSTestClient
if not "!FAILED!"=="0" goto :done_fail

REM -- certs must sit beside the binaries; both programs locate them via
REM    FindCertDir, and a missing cert dir fails the handshake in a way that
REM    reads like a TLS defect rather than a setup mistake.
if not exist "%~dp0certs\server.crt" goto :no_certs
if not exist "!EXEDIR!\certs" mkdir "!EXEDIR!\certs" 2>nul
copy /y "%~dp0certs\*" "!EXEDIR!\certs\" >nul

REM -- OpenSSL runtime. FORCE_OPENSSL selects the backend at compile time; the
REM    DLLs still have to be findable at run time or the server starts, reports
REM    itself listening, and fails every handshake. Sourced from the nghttp2
REM    provider's gRPC sample, which already ships a matching pair.
set "OSSL=!ROOT!\horse-provider-nghttp2\samples\grpc"
if not exist "!OSSL!\libcrypto-3-x64.dll" goto :no_openssl
copy /y "!OSSL!\libcrypto-3-x64.dll" "!EXEDIR!\" >nul
copy /y "!OSSL!\libssl-3-x64.dll"    "!EXEDIR!\" >nul
echo openssl: copied libcrypto-3-x64.dll + libssl-3-x64.dll

echo.
echo ===========================================================================
echo  BUILD OK
echo.
echo  Now run them per TLS-TESTS.md - server and client in SEPARATE terminals,
echo  from !EXEDIR!
echo.
echo    one-way TLS:   HorseMormotTLSTestServer          then  HorseMormotTLSTestClient
echo    mutual TLS:    HorseMormotTLSTestServer mtls     then  HorseMormotTLSTestClient mtls
echo.
echo  The CLIENT's exit code is the verdict: 0 = all assertions passed, and any
echo  other value is the number that failed. A server that never started also
echo  shows up as client failures, so check the server window first.
echo ===========================================================================
exit /b 0

:build
set "NAME=%~1"
if not exist "%~dp0!NAME!.dpr" goto :build_missing
echo -- !NAME! -----------------------------------------------------------
pushd "%~dp0"
"!DCC!" !OPTS! -A!ALIAS! -D!DEFS! -NS!NS! ^
  -U"!UPATH!" -I"!UPATH!" -R"!UPATH!" -O"!UPATH!" ^
  -E"!EXEDIR!" -N0"!DCUDIR!" -NU"!DCUDIR!" ^
  "!NAME!.dpr"
if errorlevel 1 goto :build_err
popd
echo    OK
exit /b 0
:build_err
popd
echo    FAILED - a real compiler error, look for [dcc64 Error] above
set "FAILED=1"
exit /b 0
:build_missing
echo    MISSING !NAME!.dpr
echo    These programs live in patches/horse-provider-mormot/tests/ and have
echo    never been committed to this repo. Copy them here first.
set "FAILED=1"
exit /b 0

:try_version
set "CAND=%ProgramFiles(x86)%\Embarcadero\Studio\%~1\bin\dcc64.exe"
if exist "!CAND!" if not defined DCC set "DCC=!CAND!"
exit /b 0

:no_dcc
echo ERROR: dcc64.exe not found. Set DELPHI_ROOT, e.g.
echo        set "DELPHI_ROOT=C:\Program Files (x86)\Embarcadero\Studio\23.0"
exit /b 2
:no_rtl
echo ERROR: Win64 RTL not found at !RTL!
exit /b 2
:no_prov
echo ERROR: provider source not found at !PROV!\src
exit /b 2
:no_mormot
echo ERROR: mORMot2 not found at !ROOT!\mORMot2\src\core
echo        Expected the sibling checkout layout: ^<root^>\mORMot2, ^<root^>\horse, ...
exit /b 2
:no_certs
echo ERROR: certs\server.crt not found next to this script.
exit /b 2
:no_openssl
echo ERROR: libcrypto-3-x64.dll not found at
echo        !OSSL!
echo        FORCE_OPENSSL selects OpenSSL at compile time, but the DLLs must be
echo        present at run time. Copy a matching libcrypto-3-x64.dll and
echo        libssl-3-x64.dll into !EXEDIR! by hand, or point OSSL elsewhere.
exit /b 2
:done_fail
echo.
echo BUILD FAILED - see above.
exit /b 1
