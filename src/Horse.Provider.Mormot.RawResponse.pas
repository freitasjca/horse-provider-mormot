unit Horse.Provider.Mormot.RawResponse;

(*
  mORMot2 IHorseRawResponse implementation
  =========================================
  Wraps THttpServerRequestAbstract in a single-method interface implementation.
  The generic TInterfacedWebResponse adapter (Horse.Provider.RawAdapters)
  delegates here to build a full TWebResponse compatible with all middleware.

  SetCustomHeader is a no-op for the standard flow — the actual header
  writing happens via the inherited CustomHeaders TStrings on
  TInterfacedWebResponse, which the response bridge reads at flush time
  and writes to THttpServerRequestAbstract.OutCustomHeaders.

  Dual-compilation: Delphi and FPC share the same implementation.
*)

{$IF DEFINED(FPC)}
{$MODE DELPHI}{$H+}
{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  mormot.core.base,
  mormot.net.http,
  mormot.net.server,
  Horse.Provider.RawInterfaces;

type
  TMormotRawResponse = class(TInterfacedObject, IHorseRawResponse)
  private
    FCtxt: THttpServerRequestAbstract;
  public
    constructor Create(const ACtxt: THttpServerRequestAbstract);

    { IHorseRawResponse }
    procedure SetCustomHeader(const AName, AValue: string);
  end;

implementation

constructor TMormotRawResponse.Create(const ACtxt: THttpServerRequestAbstract);
begin
  inherited Create;
  FCtxt := ACtxt;
end;

procedure TMormotRawResponse.SetCustomHeader(const AName, AValue: string);
begin
  { Header writes are captured by TInterfacedWebResponse's inherited
    CustomHeaders TStrings. This method is available for providers that
    want to forward headers to the transport in real time. mORMot defers
    all header writing to TMormotResponseBridge.Flush, so this is a
    no-op here. }
end;

end.
