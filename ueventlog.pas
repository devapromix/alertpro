unit uEventLog;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, Forms, StdCtrls;

type
  TfEventLog = class(TForm)
    EventsMemo: TMemo;
  public
    procedure AddEvent(const Msg: string);
  end;

var
  fEventLog: TfEventLog;

implementation

{$R *.lfm}

procedure TfEventLog.AddEvent(const Msg: string);
begin
  if EventsMemo.Lines.Count >= 500 then EventsMemo.Lines.Delete(0);
  EventsMemo.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + Msg);
  EventsMemo.SelStart := Length(EventsMemo.Text);
end;

end.