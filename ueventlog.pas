unit uEventLog;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, Forms, StdCtrls, Windows;

type
  TfEventLog = class(TForm)
    EventsMemo: TMemo;
  private
    LogPath: string;
    procedure DisplayLine(const Line: string);
  public
    procedure LoadHistory(const FileName: string);
    procedure AddEvent(const Msg: string);
  end;

var
  fEventLog: TfEventLog;

implementation

{$R *.lfm}

procedure TfEventLog.DisplayLine(const Line: string);
begin
  if EventsMemo.Lines.Count >= 500 then EventsMemo.Lines.Delete(0);
  EventsMemo.Lines.Add(Line);
  EventsMemo.SelStart := Length(EventsMemo.Text);
end;

procedure TfEventLog.LoadHistory(const FileName: string);
var History: TStringList;
    I, First: Integer;
begin
  LogPath := FileName;
  if not FileExists(LogPath) then Exit;
  History := TStringList.Create;
  try
    try
      History.LoadFromFile(LogPath);
      First := History.Count - 500;
      if First < 0 then First := 0;
      for I := First to History.Count - 1 do EventsMemo.Lines.Add(History[I]);
      EventsMemo.SelStart := Length(EventsMemo.Text);
    except
      on E: Exception do DisplayLine(Format('Помилка читання alertpro.log: %s', [E.Message]));
    end;
  finally
    History.Free;
  end;
end;

procedure TfEventLog.AddEvent(const Msg: string);
var Line, RecordData, CleanMessage: string;
    LogHandle: THandle;
    Written: DWORD;
begin
  CleanMessage := StringReplace(Msg, #13, ' ', [rfReplaceAll]);
  CleanMessage := StringReplace(CleanMessage, #10, ' ', [rfReplaceAll]);
  Line := FormatDateTime('yyyy-mm-dd hh-nn-ss', Now) + ' ' + CleanMessage;
  DisplayLine(Line);
  try
    RecordData := Line + LineEnding;
    LogHandle := CreateFileW(PWideChar(UTF8Decode(LogPath)), FILE_APPEND_DATA,
      FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, 0);
    if LogHandle = INVALID_HANDLE_VALUE then RaiseLastOSError;
    try
      if not WriteFile(LogHandle, RecordData[1], Length(RecordData), Written, nil) then
        RaiseLastOSError;
      if Written <> DWORD(Length(RecordData)) then
        raise EWriteError.Create('Неповний запис події');
    finally
      CloseHandle(LogHandle);
    end;
  except
    on E: Exception do DisplayLine(Format('Помилка запису alertpro.log: %s', [E.Message]));
  end;
end;

end.