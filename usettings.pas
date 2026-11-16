unit uSettings;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses Forms, StdCtrls, Controls, Graphics, Windows;

type
  TfSettings = class(TForm)
    ApiKeyLabel: TLabel;
    ApiKeyEdit: TEdit;
    StartWithWindows: TCheckBox;
    SaveButton: TButton;
    CancelButton: TButton;
    procedure FormShow(Sender: TObject);
  end;

var
  fSettings: TfSettings;

implementation

{$R *.lfm}

type
  TCheckBoxAccess = class(TCheckBox);

function SetCheckBoxWindowTheme(Wnd: HWND; SubApp, SubIdList: PWideChar): HRESULT;
  stdcall; external 'uxtheme.dll' name 'SetWindowTheme';

procedure TfSettings.FormShow(Sender: TObject);
var EmptyTheme: WideChar;
begin
  EmptyTheme := #0;
  SetCheckBoxWindowTheme(StartWithWindows.Handle, @EmptyTheme, @EmptyTheme);
  TCheckBoxAccess(StartWithWindows).ControlStyle :=
    TCheckBoxAccess(StartWithWindows).ControlStyle + [csOpaque];
  StartWithWindows.Color := Color;
  StartWithWindows.Font.Color := clWhite;
  StartWithWindows.Invalidate;
end;

end.