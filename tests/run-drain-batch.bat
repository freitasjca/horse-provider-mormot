@echo off
setlocal EnableDelayedExpansion
REM ===========================================================================
REM  run-drain-batch.bat - characterise an INTERMITTENT reply loss.
REM
REM  Usage:  run-drain-batch.bat [RUNS] [SETTLE_MS]      (default 60, unset)
REM
REM  Why 60 and not 10. One reply loss was seen in 20 runs at settle 0, so the
REM  rate to rule out is about 5%. P(all pass | 5% rate): 10 runs 59.9%,
REM  20 runs 35.8%, 60 runs 4.6%, 100 runs 0.6%. A clean 10-run arm therefore
REM  says almost nothing, which is exactly what the first A/B showed - both arms
REM  passed and neither answered the question.
REM
REM  Each deliver run costs about 2.5 s since C0 uses the 1500 ms route, so
REM  60 runs is roughly 3 minutes.
REM ===========================================================================

set "RUNS=%~1"
if "!RUNS!"=="" set "RUNS=60"
set "SETTLE=%~2"

cd /d "%~dp0"
if not exist "bin\HorseMormotDrainTest.exe" goto :no_exe

if not "!SETTLE!"=="" (
  set "HORSE_MORMOT_SETTLE_MS=!SETTLE!"
  echo settle: !SETTLE! ms
) else (
  set "HORSE_MORMOT_SETTLE_MS="
  echo settle: provider default
)
echo runs:   !RUNS!
REM  Backend under test (B7): HORSE_MORMOT_TEST_BACKEND = threadpool, async or
REM  httpapi, read by the probe itself; unset keeps the define-selected default.
REM  httpapi needs Administrator or a one-time urlacl for the probe's port:
REM    netsh http add urlacl url=http://+:9202/ user=%USERNAME%
set "BACKEND=%HORSE_MORMOT_TEST_BACKEND%"
if "!BACKEND!"=="" (set "BACKEND_LABEL=default") else (set "BACKEND_LABEL=!BACKEND!")
echo backend: !BACKEND_LABEL!
echo.

set /a PASS=0
set /a FAIL=0
set /a VOIDS=0

for /L %%I in (1,1,!RUNS!) do (
  bin\HorseMormotDrainTest.exe > "%TEMP%\drainbatch.log" 2>&1
  set "RC=!ERRORLEVEL!"
  REM A probe built before HorseMormotTestBackend ignores the variable and would
  REM report a threadpool result as the backend that was asked for. Only checked
  REM below exit 2: a VOID run prints its own reason, and a typo in the variable is one.
  if not "!BACKEND!"=="" if !RC! LSS 2 (
    findstr /I /L /C:"backend: !BACKEND! " "%TEMP%\drainbatch.log" >nul 2>&1
    if errorlevel 1 set "RC=WRONG"
  )
  if "!RC!"=="WRONG" (
    set /a VOIDS+=1
    echo   run %%I: VOID - the probe did not report backend !BACKEND!; rebuild it
    if %%I==1 goto :first_void
  ) else if !RC! GEQ 2 (
    set /a VOIDS+=1
    echo   run %%I: VOID - nothing was tested
    type "%TEMP%\drainbatch.log"
    if %%I==1 goto :first_void
  ) else if !RC! GEQ 1 (
    set /a FAIL+=1
    echo   run %%I: FAIL
    REM Keep the whole failing run. An intermittent is only diagnosable from the
    REM output of the run that failed, and it is gone on the next iteration.
    copy /y "%TEMP%\drainbatch.log" "fail-%%I.log" >nul
    findstr /C:"in-flight" /C:"elapsed" /C:"headers" "%TEMP%\drainbatch.log"
  ) else (
    set /a PASS+=1
  )
)

echo.
echo ===========================================================================
echo  [backend !BACKEND_LABEL!]  passed !PASS! / !RUNS!   failed !FAIL!   void !VOIDS!
if !FAIL! GTR 0 echo  failing runs saved as fail-N.log in this directory
echo ===========================================================================
if !VOIDS! GTR 0 exit /b 2
exit /b !FAIL!

:first_void
REM  A VOID on the FIRST run is the environment (a held port, a missing http.sys
REM  URL reservation, a bad HORSE_MORMOT_TEST_BACKEND), not an intermittent: the
REM  other runs would print the same failure. B7's first httpapi batch did, 20 times.
echo.
echo ===========================================================================
echo  [backend !BACKEND_LABEL!]  VOID on run 1 - batch stopped, nothing was tested.
echo  Fix the reason printed above and run again.
echo ===========================================================================
exit /b 2

:no_exe
echo ERROR: bin\HorseMormotDrainTest.exe not found - run build-drain-dcc.bat first.
exit /b 2
