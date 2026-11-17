unit uUpdater;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses Classes, SysUtils;

const
  AlertProVersion = '8.1.0';
  UpdateRepository = 'devapromix/alertpro';

type
  TUpdateJob = class(TThread)
  public
    StagePath, Version, ErrorText: string;
    procedure Execute; override;
  end;

function UpdateStagePath: string;
procedure LaunchUpdateHelper;
function RunUpdateHelper: Boolean;
procedure CleanUpdateHelper;

implementation

uses Windows, StrUtils, Process, ActiveX, ComObj, Variants, fpjson, jsonparser, LazFileUtils;

const
  ReleaseAsset = 'alertpro.exe';
  MaxUpdateBytes = 100 * 1024 * 1024;
  ApplyFlag = '--apply-update';
  CleanupFlag = '--cleanup-update';

function CryptHashCertificate2(Algorithm: PWideChar; Flags: DWORD;
  Reserved, Data: Pointer; DataSize: DWORD; Hash: Pointer;
  var HashSize: DWORD): LongBool; stdcall; external 'crypt32.dll';

function ReplaceExecutable(Target, Replacement, Backup: PWideChar;
  Flags: DWORD; Exclude, Reserved: Pointer): LongBool;
  stdcall; external 'kernel32.dll' name 'ReplaceFileW';

type TVersionParts = array[0..2] of Cardinal;

function ParseVersion(const Tag: string; out Parts: TVersionParts): Boolean;
var S, Number: string;
    I, P, N: Integer;
    C: Char;
begin
  Result := False;
  S := Tag;
  if (S <> '') and (S[1] in ['v', 'V']) then
  begin
    Delete(S, 1, 1);
    if (S <> '') and (S[1] = '.') then Delete(S, 1, 1);
  end;
  for I := Low(Parts) to High(Parts) do
  begin
    P := Pos('.', S);
    if I = High(Parts) then P := Length(S) + 1 else if P = 0 then Exit;
    Number := Copy(S, 1, P - 1);
    if Number = '' then Exit;
    for C in Number do if not (C in ['0'..'9']) then Exit;
    if not TryStrToInt(Number, N) then Exit;
    Parts[I] := N;
    Delete(S, 1, P);
  end;
  Result := True;
end;

function IsNewer(const Tag: string): Boolean;
var Remote, Local: TVersionParts;
    I: Integer;
begin
  if not ParseVersion(Tag, Remote) or not ParseVersion(AlertProVersion, Local) then
    raise Exception.Create('Тег версії має вигляд v8.0.0 або v.8.0.0');
  for I := Low(Remote) to High(Remote) do
    if Remote[I] <> Local[I] then Exit(Remote[I] > Local[I]);
  Result := False;
end;

function NewRequest(const URL: string): OleVariant;
begin
  Result := CreateOleObject('WinHttp.WinHttpRequest.5.1');
  Result.SetTimeouts(5000, 5000, 10000, 20000);
  Result.Open('GET', WideString(UTF8Decode(URL)), False);
  Result.SetRequestHeader('User-Agent', 'AlertPro-Updater');
end;

procedure SaveVerifiedAsset(var Body: OleVariant; const Digest, Path: string;
  ExpectedSize: Int64);
var Buffer: Pointer;
    Size, HashSize: DWORD;
    Hash: array[0..31] of Byte;
    Hex: string;
    I: Integer;
    FileStream: TFileStream;
begin
  if not VarIsArray(Body) or (VarArrayDimCount(Body) <> 1) then
    raise Exception.Create('GitHub повернув некоректний файл оновлення');
  Size := VarArrayHighBound(Body, 1) - VarArrayLowBound(Body, 1) + 1;
  if (Size <> ExpectedSize) or (Size < 2) or (Size > MaxUpdateBytes) then
    raise Exception.Create('Розмір EXE не збігається з релізом');
  Buffer := VarArrayLock(Body);
  try
    if (PByte(Buffer)^ <> $4D) or (PByte(Buffer)[1] <> $5A) then
      raise Exception.Create('Файл оновлення не є Windows EXE');
    HashSize := SizeOf(Hash);
    if not CryptHashCertificate2(PWideChar(UnicodeString('SHA256')), 0, nil, Buffer, Size, @Hash[0], HashSize)
       or (HashSize <> SizeOf(Hash)) then RaiseLastOSError;
    Hex := '';
    for I := Low(Hash) to High(Hash) do Hex := Hex + IntToHex(Hash[I], 2);
    if not SameText(Digest, 'sha256:' + Hex) then
      raise Exception.Create('SHA-256 файлу не збігається з релізом');
    FileStream := TFileStream.Create(Path, fmCreate);
    try
      FileStream.WriteBuffer(Buffer^, Size);
    finally
      FileStream.Free;
    end;
  finally
    VarArrayUnlock(Body);
  end;
end;

procedure TUpdateJob.Execute;
var HTTP, Body: OleVariant;
    Release, Assets, Item: TJSONData;
    Tag, URL, Digest, ExpectedURL: string;
    I: Integer;
    Size: Int64;
begin
  CoInitialize(nil);
  try
    try
      HTTP := NewRequest('https://api.github.com/repos/' + UpdateRepository + '/releases/latest');
      HTTP.Option[6] := False;
      HTTP.SetRequestHeader('Accept', 'application/vnd.github+json');
      HTTP.Send;
      if Integer(HTTP.Status) <> 200 then
        raise Exception.CreateFmt('GitHub Releases: HTTP %d', [Integer(HTTP.Status)]);
      if Terminated then Exit;
      Release := GetJSON(UTF8Encode(UnicodeString(HTTP.ResponseText)));
      try
        if not (Release is TJSONObject) then
          raise Exception.Create('Некоректна відповідь GitHub Releases');
        Tag := TJSONObject(Release).Get('tag_name', '');
        if not IsNewer(Tag) then Exit;
        Assets := TJSONObject(Release).Find('assets');
        if not (Assets is TJSONArray) then
          raise Exception.Create('У релізі відсутні файли');
        Size := 0;
        for I := 0 to Assets.Count - 1 do
        begin
          Item := Assets.Items[I];
          if (Item is TJSONObject) and (TJSONObject(Item).Get('name', '') = ReleaseAsset) then
          begin
            URL := TJSONObject(Item).Get('browser_download_url', '');
            Digest := TJSONObject(Item).Get('digest', '');
            Size := TJSONObject(Item).Get('size', Int64(0));
            Break;
          end;
        end;
      finally
        Release.Free;
      end;
      ExpectedURL := 'https://github.com/' + UpdateRepository + '/releases/download/' + Tag + '/' + ReleaseAsset;
      if not SameText(URL, ExpectedURL) or (Length(Digest) <> 71) or
        (Size <= 0) or (Size > MaxUpdateBytes) then
        raise Exception.Create('Реліз має містити alertpro.exe з SHA-256');
      if Terminated then Exit;
      HTTP := NewRequest(URL);
      HTTP.Send;
      if Integer(HTTP.Status) <> 200 then
        raise Exception.CreateFmt('Завантаження EXE: HTTP %d', [Integer(HTTP.Status)]);
      if Terminated then Exit;
      Body := HTTP.ResponseBody;
      SaveVerifiedAsset(Body, Digest, StagePath, Size);
      Version := Tag;
    except
      on E: Exception do
      begin
        DeleteFileUTF8(StagePath);
        ErrorText := E.Message;
      end;
    end;
  finally
    Body := Unassigned;
    HTTP := Unassigned;
    CoUninitialize;
  end;
end;

function UpdateSuffix(PID: DWORD): string;
begin
  Result := '.' + IntToStr(PID) + '.update';
end;

function UpdateStagePath: string;
begin
  Result := ParamStr(0) + UpdateSuffix(GetCurrentProcessId) + '.download';
end;

procedure StartProcess(const Exe: string; Flags: array of string);
var P: TProcess;
    Flag: string;
begin
  P := TProcess.Create(nil);
  try
    P.Executable := Exe;
    P.CurrentDirectory := ExtractFileDir(Exe);
    P.Options := [poNoConsole];
    for Flag in Flags do P.Parameters.Add(Flag);
    P.Execute;
  finally
    P.Free;
  end;
end;

procedure LaunchUpdateHelper;
var Source, Helper: string;
    PID: DWORD;
begin
  PID := GetCurrentProcessId;
  Source := ParamStr(0);
  Helper := Source + UpdateSuffix(PID) + '-helper.exe';
  if not CopyFileW(PWideChar(UTF8Decode(Source)), PWideChar(UTF8Decode(Helper)), True) then
    RaiseLastOSError;
  try
    if GetPriorityClass(GetCurrentProcess) = HIGH_PRIORITY_CLASS then
      StartProcess(Helper, [ApplyFlag, IntToStr(PID), '--windows-startup'])
    else
      StartProcess(Helper, [ApplyFlag, IntToStr(PID)]);
  except
    DeleteFileUTF8(Helper);
    raise;
  end;
end;

function WaitForPreviousProcess(PID: DWORD): Boolean;
var H: THandle;
begin
  H := OpenProcess(SYNCHRONIZE, False, PID);
  if H = 0 then Exit(GetLastError = ERROR_INVALID_PARAMETER);
  try
    Result := WaitForSingleObject(H, 30000) = WAIT_OBJECT_0;
  finally
    CloseHandle(H);
  end;
end;

function RunUpdateHelper: Boolean;
var PID: Cardinal;
    Suffix, Helper, Target, Stage, Backup: string;
    ReplaceError: DWORD;
begin
  Result := (ParamCount >= 1) and (ParamStr(1) = ApplyFlag);
  if not Result then Exit;
  Helper := ParamStr(0);
  if not TryStrToDWord(ParamStr(2), PID) or (PID = 0) then Exit;
  Suffix := UpdateSuffix(PID);
  if not AnsiEndsText(Suffix + '-helper.exe', Helper) then Exit;
  Target := Copy(Helper, 1, Length(Helper) - Length(Suffix + '-helper.exe'));
  Stage := Target + Suffix + '.download';
  Backup := Target + Suffix + '.backup';
  try
    if not WaitForPreviousProcess(PID) then
      raise Exception.Create('Попередній процес не завершився');
    if not ReplaceExecutable(PWideChar(UTF8Decode(Target)), PWideChar(UTF8Decode(Stage)),
      PWideChar(UTF8Decode(Backup)), 0, nil, nil) then
    begin
      ReplaceError := GetLastError;
      if not FileExistsUTF8(Target) and FileExistsUTF8(Backup) then
        MoveFileExW(PWideChar(UTF8Decode(Backup)), PWideChar(UTF8Decode(Target)), 0);
      if FileExistsUTF8(Target) then
        StartProcess(Target, [CleanupFlag, IntToStr(PID)]);
      RaiseLastOSError(ReplaceError);
    end;
    try
      if ParamStr(3) = '--windows-startup' then
        StartProcess(Target, ['--windows-startup', CleanupFlag, IntToStr(PID)])
      else
        StartProcess(Target, [CleanupFlag, IntToStr(PID)]);
    except
      if MoveFileExW(PWideChar(UTF8Decode(Backup)), PWideChar(UTF8Decode(Target)),
        MOVEFILE_REPLACE_EXISTING) then StartProcess(Target, []);
      raise;
    end;
  except
    on E: Exception do
      MessageBoxW(0, PWideChar(UTF8Decode(E.Message)), PWideChar(UnicodeString('Alert Pro')), MB_OK or MB_ICONERROR);
  end;
end;

procedure CleanUpdateHelper;
var I, Attempt: Integer;
    PID: Cardinal;
    Base: string;
begin
  for I := 1 to ParamCount - 1 do
    if (ParamStr(I) = CleanupFlag) and TryStrToDWord(ParamStr(I + 1), PID) and (PID <> 0) then
    begin
      Base := ParamStr(0) + UpdateSuffix(PID);
      for Attempt := 1 to 20 do
      begin
        if not FileExistsUTF8(Base + '-helper.exe') or DeleteFileUTF8(Base + '-helper.exe') then Break;
        Sleep(50);
      end;
      DeleteFileUTF8(Base + '.backup');
      Break;
    end;
end;

end.
