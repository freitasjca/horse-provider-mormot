unit HorseMormotTestBackend;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// Test-only helper: run any test server against any mORMot backend without a
// rebuild, so a gate can be repeated per backend (triage item B7).
//
//   HORSE_MORMOT_TEST_BACKEND = threadpool | async | httpapi
//
// Unset or empty leaves THorseMormotConfig.Default alone, so the define-selected
// default (HORSE_MORMOT_ASYNC / HORSE_MORMOT_HTTPAPI) still applies and every
// existing run behaves exactly as before. Any other value RAISES: a typo must
// not quietly test the default backend and report it as the one asked for.
//
// Why this exists: until 2026-10 every mORMot gate (graceful drain, TLS T1-T4,
// cipher refusals) ran on mskThreadPool only, and FIX-MORMOT-TLS-1 was exactly a
// defect that passes there and fails on mskAsync. Every server prints the live
// backend through BackendName, so a result always says which backend produced it.

interface

uses
  Horse.Provider.Mormot.Config;

const
  TEST_BACKEND_ENV = 'HORSE_MORMOT_TEST_BACKEND';

// Applies HORSE_MORMOT_TEST_BACKEND to AConfig.ServerKind; raises on an unknown value.
procedure ApplyTestBackend(var AConfig: THorseMormotConfig);

// 'threadpool (THttpServer)' etc. - the first word matches the env-var value.
function BackendName(const AKind: TMormotServerKind): string;

implementation

uses
{$IF DEFINED(FPC)}
  SysUtils;
{$ELSE}
  System.SysUtils;
{$IFEND}

procedure ApplyTestBackend(var AConfig: THorseMormotConfig);
var
  LValue: string;
begin
  LValue := Trim(GetEnvironmentVariable(TEST_BACKEND_ENV));
  if LValue = '' then
    Exit;

  if SameText(LValue, 'threadpool') then
    AConfig.ServerKind := mskThreadPool
  else if SameText(LValue, 'async') then
    AConfig.ServerKind := mskAsync
  else if SameText(LValue, 'httpapi') then
    AConfig.ServerKind := mskHttpApi
  else
    raise Exception.CreateFmt(
      '%s="%s" is not a backend - use threadpool, async or httpapi',
      [TEST_BACKEND_ENV, LValue]);
end;

function BackendName(const AKind: TMormotServerKind): string;
begin
  case AKind of
    mskAsync:   Result := 'async (THttpAsyncServer)';
    mskHttpApi: Result := 'httpapi (THttpApiServer, http.sys)';
  else
    Result := 'threadpool (THttpServer)';
  end;
end;

end.
