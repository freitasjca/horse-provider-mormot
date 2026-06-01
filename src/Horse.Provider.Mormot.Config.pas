unit Horse.Provider.Mormot.Config;

(*
  Horse mORMot Provider — Configuration record
  =============================================
  THorseMormotConfig is the single configuration point for the mORMot2
  transport.  It is a pure data record with no dependencies on Horse or
  mORMot so it can be referenced by both the abstract base and the
  provider without circular units.

  Dual-compilation: Delphi and FPC.
*)

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

const
  MORMOT_DEFAULT_THREAD_POOL       = 32;
  MORMOT_DEFAULT_MAX_BODY_BYTES    = Int64(4) * 1024 * 1024;  // 4 MB
  MORMOT_DEFAULT_MAX_HEADER_COUNT  = 100;
  MORMOT_DEFAULT_DRAIN_TIMEOUT_MS  = 5000;

type
  THorseMormotConfig = record
    // mORMot THttpServer internal thread-pool size.
    // Each thread handles one concurrent request synchronously.
    // Default: 32
    ThreadPool:     Integer;

    // Maximum request body size (bytes).
    // Enforced by TMormotRequestBridge.Validate before the pipeline runs.
    // Default: 4 MB
    MaxBodyBytes:   Int64;

    // Maximum number of headers per request.
    // Excess headers are silently dropped (same as the CrossSocket provider).
    // Default: 100
    MaxHeaderCount: Integer;

    // Milliseconds to wait for in-flight requests to complete on Stop.
    // After this timeout shutdown proceeds regardless.
    // Default: 5000
    DrainTimeoutMs: Integer;

    // Value emitted in the HTTP Server: response header.
    // Empty string → 'unknown' to prevent library/version fingerprinting.
    // Default: ''
    ServerBanner:   string;

    class function Default: THorseMormotConfig; static;
  end;

implementation

class function THorseMormotConfig.Default: THorseMormotConfig;
begin
  Result.ThreadPool     := MORMOT_DEFAULT_THREAD_POOL;
  Result.MaxBodyBytes   := MORMOT_DEFAULT_MAX_BODY_BYTES;
  Result.MaxHeaderCount := MORMOT_DEFAULT_MAX_HEADER_COUNT;
  Result.DrainTimeoutMs := MORMOT_DEFAULT_DRAIN_TIMEOUT_MS;
  Result.ServerBanner   := '';
end;

end.
