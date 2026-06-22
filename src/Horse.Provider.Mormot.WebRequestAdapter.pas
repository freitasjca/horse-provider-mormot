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
  mormot.core.unicode,
  mormot.core.buffers,
  mormot.net.http,
  mormot.net.server,
  Horse.Provider.RawInterfaces,
  Horse.Provider.RawAdapters,
  Horse.Provider.Mormot.RawRequest;

type
  TMormotWebRequest = class(TInterfacedWebRequest)
  private
{$IF DEFINED(FPC)}
    procedure PopulateMultipartFiles(const ACtxt: THttpServerRequestAbstract);
{$ENDIF}
  public
    constructor Create(const ACtxt: THttpServerRequestAbstract); reintroduce;
    destructor Destroy; override;
  end;

implementation

constructor TMormotWebRequest.Create(const ACtxt: THttpServerRequestAbstract);
begin
  inherited Create(TMormotRawRequest.Create(ACtxt));
{$IF DEFINED(FPC)}
  PopulateMultipartFiles(ACtxt);
{$ENDIF}
end;

destructor TMormotWebRequest.Destroy;
begin
{$IF DEFINED(FPC)}
  DeleteTempUploadedFiles;
{$ENDIF}
  inherited Destroy;
end;

{$IF DEFINED(FPC)}
{-----------------------------------------------------------------------------
 Popula RawWebRequest.Files quando o provider mORMot recebe multipart/form-data.
 -----------------------------------------------------------------------------}
procedure TMormotWebRequest.PopulateMultipartFiles(
  const ACtxt: THttpServerRequestAbstract);
var
  LParts: TMultiPartDynArray;
  LIndex: Integer = 0;
  LName: String = '';
  LFileName: String = '';
  LTempFileName: String = '';
  LFile: TUploadedFile = nil;
  LStream: TFileStream = nil;
  LContentType: String = '';
begin
  LContentType := LowerCase(Utf8ToString(ACtxt.InContentType));
  if Pos('multipart/form-data', LContentType) <= 0 then
    Exit;

  if Length(ACtxt.InContent) <= 0 then
    Exit;

  if not MultiPartFormDataDecode(ACtxt.InContentType, RawUtf8(ACtxt.InContent), LParts) then
    Exit;

  for LIndex := 0 to High(LParts) do
  begin
    LName := Utf8ToString(LParts[LIndex].Name);
    if LName = EmptyStr then
      Continue;

    if LParts[LIndex].FileName <> '' then
    begin
      LFileName := ExtractFileName(Utf8ToString(LParts[LIndex].FileName));

      LFile := Files.Add as TUploadedFile;
      LFile.FieldName := LName;
      LFile.FileName := LFileName;
      LFile.ContentType := Utf8ToString(LParts[LIndex].ContentType);
      LFile.Disposition := 'form-data';
      LFile.Size := Length(LParts[LIndex].Content);
      LFile.LocalFileName := GetTempUploadFileName(LName, LFileName, LFile.Size);

      LTempFileName := LFile.LocalFileName;
      LStream := TFileStream.Create(LTempFileName, fmCreate);
      try
        if Length(LParts[LIndex].Content) > 0 then
          LStream.WriteBuffer(Pointer(LParts[LIndex].Content)^,
            Length(LParts[LIndex].Content));
      finally
        FreeAndNil(LStream);
      end;
    end
    else
    begin
      ContentFields.Values[LName] := Utf8ToString(RawUtf8(LParts[LIndex].Content));
    end;
  end;
end;
{$ENDIF}

end.
