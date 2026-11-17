program alertpro;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF HASAMIGA}
  athreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, uMainForm, uUpdater
  { you can add units after this };

{$R *.res}

begin
  if RunUpdateHelper then Halt;
  RequireDerivedFormResource:=True;
  Application.Scaled:=True;
  {$PUSH}{$WARN 5044 OFF}
  Application.MainFormOnTaskbar := True;
  {$POP}
  Application.Initialize;
  Application.CreateForm(TfMainForm, fMainForm);
  Application.ShowMainForm := False;
  CleanUpdateHelper;
  Application.Run;
end.

