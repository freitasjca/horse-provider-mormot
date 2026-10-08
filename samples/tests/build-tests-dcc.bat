@echo off
setlocal enabledelayedexpansion
REM ===========================================================================
REM  build-tests-dcc.bat - build the port-9010 integration test pair with dcc64
REM  directly. Derived from this repo's own tests\build-drain-dcc.bat, so the
REM  unit paths are ones already proven to build this provider.
REM
REM  WRITTEN BECAUSE THESE TWO PROGRAMS HAD ONLY .dproj FILES. msbuild expands
REM  the IDE's machine-wide Library Path and dies past the 32000-char command
REM  line (MSB6002 / MSB6003), so this suite was effectively unrunnable from a
REM  shell and got skipped - which is how a change to shared Horse code reaches
REM  a release having been tested against one provider out of four.
REM
REM  Usage:  build-tests-dcc.bat [Release|Debug]
REM ===========================================================================

set "TGTCONFIG=%~1"
if "!TGTCONFIG!"=="" set "TGTCONFIG=Release"
if /I "!TGTCONFIG!"=="Release" goto :cfg_ok
if /I "!TGTCONFIG!"=="Debug"   goto :cfg_ok
echo ERROR: config must be Release or Debug, got "!TGTCONFIG!".
exit /b 2
:cfg_ok

cd /d "%~dp0"
set "FAILED="

if not "%DELPHI_ROOT%"=="" if exist "%DELPHI_ROOT%\bin\dcc64.exe" set "DCC=%DELPHI_ROOT%\bin\dcc64.exe"
if not defined DCC for %%V in (23.0 22.0 21.0 20.0 19.0) do call :try_version %%V
if not defined DCC for /f "delims=" %%I in ('where dcc64.exe 2^>nul') do if not defined DCC set "DCC=%%I"
if not defined DCC goto :no_dcc

for %%I in ("!DCC!") do set "DCCDIR=%%~dpI"
for %%I in ("!DCCDIR!..") do set "BDSROOT=%%~fI"
set "RTL=!BDSROOT!\lib\Win64\release"
if /I "!TGTCONFIG!"=="Debug" set "RTL=!BDSROOT!\lib\Win64\debug"
if not exist "!RTL!" goto :no_rtl

REM  This script lives in samples\tests\, so the provider root is TWO
REM  levels up - the drain script sits in tests\ and uses one.
for %%I in ("%~dp0..\..") do set "PROV=%%~fI"
for %%I in ("!PROV!\..") do set "ROOT=%%~fI"

set "UPATH=!RTL!;!PROV!\src;!ROOT!\horse\src"
set "UPATH=!UPATH!;!ROOT!\mORMot2\src\core;!ROOT!\mORMot2\src\net;!ROOT!\mORMot2\src\lib"
set "UPATH=!UPATH!;!ROOT!\mORMot2\src\crypt;!ROOT!\mORMot2\static\delphi"
REM  The suite CLIENT uses Net.CrossHttpClient and Net.CrossHttpParams from
REM  Delphi-Cross-Socket. This provider does not, which is why the drain script
REM  this was derived from never needed these paths.
REM  -I needs BOTH the DCS root and CnPack\Common: every DCS unit opens with
REM  {$I zLib.inc} and every CnPack unit with {$I CnPack.inc}, and a unit path
REM  (-U) does not satisfy an include.
set "DCS=!ROOT!\Delphi-Cross-Socket"
if not exist "!DCS!\Net" goto :no_dcs
set "UPATH=!UPATH!;!DCS!;!DCS!\Net;!DCS!\Utils;!DCS!\DelphiToFPC"
set "UPATH=!UPATH!;!DCS!\CnPack\Common;!DCS!\CnPack\Crypto"
set "IPATH=!UPATH!;!DCS!;!DCS!\CnPack\Common"

if not exist "!PROV!\src\Horse.Provider.Mormot.Config.pas" goto :no_prov
if not exist "!ROOT!\mORMot2\src\core"                     goto :no_mormot

set "NS=Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win;System;Xml;Data;Datasnap;Web;Soap"
set "ALIAS=Generics.Collections=System.Generics.Collections;Generics.Defaults=System.Generics.Defaults;WinTypes=Winapi.Windows;WinProcs=Winapi.Windows;DbiTypes=BDE;DbiProcs=BDE;DbiErrs=BDE"
set "DEFS=!TGTCONFIG!;HORSE_PROVIDER_MORMOT"
set "OPTS=--no-config -B -Q -TX.exe"
if /I "!TGTCONFIG!"=="Release" set "OPTS=!OPTS! -$D0 -$L- -$Y-"

set "EXEDIR=%~dp0bin"
set "DCUDIR=%~dp0temp"
if not exist "!EXEDIR!" mkdir "!EXEDIR!" 2>nul
if not exist "!DCUDIR!" mkdir "!DCUDIR!" 2>nul

echo dcc64:  !DCC!
echo config: !TGTCONFIG!
echo DCS:    !DCS!
echo out:    !EXEDIR!
echo.

for %%P in (HorseMormotTestServer HorseMormotTestClient) do call :build %%P
if defined FAILED goto :build_err
echo.
echo ===========================================================================
echo  BUILT   HorseMormotTestServer.exe + HorseMormotTestClient.exe  (in bin\)
echo.
echo  Run in two terminals from HERE:
echo.
echo    bin\HorseMormotTestServer      terminal 1  (listens on 127.0.0.1:9010)
echo    bin\HorseMormotTestClient      terminal 2
echo.
echo  Client exit code = number of failed checks; 0 means all passed.
echo  Green baseline: 131/131 thread pool + async, 127/131 http.sys (tests 04/15:
echo  the client omits Content-Length on empty bodies). 128 before test 48.
echo.
echo  PORT 9010 IS SHARED with the CrossSocket and ICS suites, so only
echo  one server may run at a time. Windows lets a second process bind the same
echo  port with NO error (SO_REUSEADDR) and the stale one keeps answering, so a
echo  run can look green while testing the wrong binary. Before starting:
echo      taskkill /IM HorseMormotTestServer.exe /F
echo ===========================================================================
exit /b 0

:build_err
echo    FAILED - a real compiler error, look for [dcc64 Error] above
exit /b 1

:build
set "NAME=%~1"
if not exist "%~dp0!NAME!.dpr" (
  echo    SKIP  !NAME!.dpr not present
  set "FAILED=1"
  exit /b 0
)
echo -- !NAME! -----------------------------------------------------------
"!DCC!" !OPTS! -A!ALIAS! -D!DEFS! -NS!NS! ^
  -U"!UPATH!" -I"!IPATH!" -R"!UPATH!" -O"!UPATH!" ^
  -E"!EXEDIR!" -N0"!DCUDIR!" -NU"!DCUDIR!" ^
  "!NAME!.dpr"
REM  A multi-line block, NOT (set X ^& exit /b 0): cmd does not reliably honour
REM  `exit /b` inside a parenthesised compound, and the one-line form printed OK
REM  straight after a fatal compiler error.
if errorlevel 1 (
  echo    FAILED
  set "FAILED=1"
  exit /b 0
)
echo    OK
exit /b 0

:try_version
set "CAND=%ProgramFiles(x86)%\Embarcadero\Studio\%~1\bin\dcc64.exe"
if exist "!CAND!" if not defined DCC set "DCC=!CAND!"
exit /b 0

:no_dcs
echo ERROR: Delphi-Cross-Socket not found at !DCS!\Net
echo        The test CLIENT needs it even though this provider does not.
exit /b 2
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
exit /b 2
:no_src
echo ERROR: !NAME!.dpr not found in %~dp0
exit /b 2
