unit Horse.Provider.Mormot.WebRequestAdapter;

(*
  Horse mORMot Provider - TWebRequest / TRequest adapter
  ------------------------------------------------------
  Thin subclass of TInterfacedWebRequest.
  The constructor creates a TMormotRawRequest and passes it to the
  generic TInterfacedWebRequest adapter.

  Uses:
    THttpServerRequestAbstract → TMormotRawRequest (IHorseRawRequest)
                               → TInterfacedWebRequest (TWebRequest/TRequest)
                                 = TMormotWebRequest

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
  Horse.Provider.Mormot.RawRequest;

type
  TMormotWebRequest = class(TInterfacedWebRequest)
  public
    constructor Create(const ACtxt: THttpServerRequestAbstract); reintroduce;
  end;

implementation

constructor TMormotWebRequest.Create(const ACtxt: THttpServerRequestAbstract);
begin
  inherited Create(TMormotRawRequest.Create(ACtxt));
end;

end.
