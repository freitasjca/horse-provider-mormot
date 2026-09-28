@echo off
setlocal enabledelayedexpansion
REM ===========================================================================
REM  build-drain-dcc.bat
REM  Build HorseMormotDrainTest by invoking dcc64 DIRECTLY.
REM
REM  Separate from build-tls-dcc.bat on purpose: this probe is plain HTTP on
REM  port 9202 and needs no certs, no OpenSSL DLLs and no FORCE_OPENSSL. Folding
REM  it into the TLS script would make a TLS toolchain a prerequisite for a
REM  question that has nothing to do with TLS.
REM
REM  What it answers: whether StopListenGraceful(N) is bounded by N. See the
REM  header of HorseMormotDrainTest.dpr.
REM
REM  No parenthesised blocks - same cmd quirk the sibling scripts document.
REM
REM  Usage:  build-drain-dcc.bat [Release^|Debug]      (default Release)
REM  Win64 only. Run from this tests\ folder.
REM ===========================================================================

set "TGTCONFIG=%~1"
if "!TGTCONFIG!"=="" set "TGTCONFIG=Release"
if /I "!TGTCONFIG!"=="Release" goto :cfg_ok
if /I "!TGTCONFIG!"=="Debug"   goto :cfg_ok
echo ERROR: config must be Release or Debug, got "!TGTCONFIG!".
exit /b 2
:cfg_ok

cd /d "%~dp0"

if not "%DELPHI_ROOT%"=="" if exist "%DELPHI_ROOT%\bin\dcc64.exe" set "DCC=%DELPHI_ROOT%\bin\dcc64.exe"
if not defined DCC for %%V in (23.0 22.0 21.0 20.0 19.0) do call :try_version %%V
if not defined DCC for /f "delims=" %%I in ('where dcc64.exe 2^>nul') do if not defined DCC set "DCC=%%I"
if not defined DCC goto :no_dcc

for %%I in ("!DCC!") do set "DCCDIR=%%~dpI"
for %%I in ("!DCCDIR!..") do set "BDSROOT=%%~fI"
set "RTL=!BDSROOT!\lib\Win64\release"
if /I "!TGTCONFIG!"=="Debug" set "RTL=!BDSROOT!\lib\Win64\debug"
if not exist "!RTL!" goto :no_rtl

for %%I in ("%~dp0..") do set "PROV=%%~fI"
for %%I in ("!PROV!\..") do set "ROOT=%%~fI"

set "UPATH=!RTL!;!PROV!\src;!ROOT!\horse\src"
set "UPATH=!UPATH!;!ROOT!\mORMot2\src\core;!ROOT!\mORMot2\src\net;!ROOT!\mORMot2\src\lib"
set "UPATH=!UPATH!;!ROOT!\mORMot2\src\crypt;!ROOT!\mORMot2\static\delphi"

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
echo out:    !EXEDIR!
echo.

set "NAME=HorseMormotDrainTest"
if not exist "%~dp0!NAME!.dpr" goto :no_src
echo -- !NAME! -----------------------------------------------------------
"!DCC!" !OPTS! -A!ALIAS! -D!DEFS! -NS!NS! ^
  -U"!UPATH!" -I"!UPATH!" -R"!UPATH!" -O"!UPATH!" ^
  -E"!EXEDIR!" -N0"!DCUDIR!" -NU"!DCUDIR!" ^
  "!NAME!.dpr"
if errorlevel 1 goto :build_err
echo    OK
echo.
echo ===========================================================================
echo  BUILD OK
echo.
echo  Run it directly - it starts and stops its own server on port 9202:
echo    bin\HorseMormotDrainTest.exe
echo.
echo  Exit code 0 = the in-flight reply was DELIVERED and the drain returned
echo  inside its timeout, N = that many assertions failed, 2 = VOID.
echo.
echo  Add the argument "bound" for the report-only case (timeout shorter than
echo  the work left): bin\HorseMormotDrainTest.exe bound
echo ===========================================================================
exit /b 0

:build_err
echo    FAILED - a real compiler error, look for [dcc64 Error] above
exit /b 1

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
exit /b 2
:no_src
echo ERROR: !NAME!.dpr not found in %~dp0
exit /b 2
