unit Horse.Provider.Mormot.WebResponseAdapter;

(*
  Horse mORMot Provider - TWebResponse / TResponse adapter
  --------------------------------------------------------
  Thin subclass of TInterfacedWebResponse.
  The constructor creates a TMormotRawResponse and passes it to the
  generic TInterfacedWebResponse adapter.

  Uses:
    THttpServerRequestAbstract → TMormotRawResponse (IHorseRawResponse)
                               → TInterfacedWebResponse (TWebResponse/TResponse)
                                 = TMormotWebResponse

  Dual-compilation: Delphi and FPC.
*)

{$IF DEFINED(FPC)}
{$MODE DELPHI}{$H+}
{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
  fpHTTP,
  HTTPDefs,
{$ELSE}
  System.SysUtils,
  System.Classes,
  Web.HTTPApp,
{$ENDIF}
  mormot.core.base,
  mormot.net.http,
  mormot.net.server,
  Horse.Provider.RawInterfaces,
  Horse.Provider.RawAdapters,
  Horse.Provider.Mormot.RawResponse;

type
  TMormotWebResponse = class(TInterfacedWebResponse)
  public
    constructor Create(const ACtxt: THttpServerRequestAbstract); reintroduce;
  end;

implementation

constructor TMormotWebResponse.Create(const ACtxt: THttpServerRequestAbstract);
begin
  inherited Create(TMormotRawResponse.Create(ACtxt));
end;

end.
