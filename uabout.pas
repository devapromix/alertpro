unit uAbout;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses Forms, StdCtrls;

type
  TfAbout = class(TForm)
    TitleLabel, VersionLabel, AuthorsLabel, CopyrightLabel: TLabel;
    CloseButton: TButton;
    procedure FormCreate(Sender: TObject);
  end;

var
  fAbout: TfAbout;

implementation

uses uUpdater;

{$R *.lfm}

procedure TfAbout.FormCreate(Sender: TObject);
begin
  VersionLabel.Caption := 'Версія ' + AlertProVersion;
end;

end.
