unit uMainForm;
{$mode objfpc}{$H+}{$codepage utf8}
interface

uses Forms, Controls, StdCtrls, ExtCtrls, Graphics, Classes, Menus, Dialogs,
  SysUtils, Types, Windows, Registry, MMSystem, ActiveX, ComObj, Variants, fpjson, jsonparser, uEventLog, uSettings, LazFileUtils, uUpdater, uAbout;

type
  TApiJob = class(TThread)
    Kind, Token, ErrorText: string;
    Data: TJSONData;
    Diagnostic: Boolean;
    procedure Execute; override;
    destructor Destroy; override;
  end;
  TfMainForm = class(TForm)
    Status: TLabel;
    RegionLabel, ApiLabel: TLabel;
    TitleLabel: TLabel;
    StatusSurface: TShape;
    GearButton: TButton;
    SettingsMenu: TPopupMenu;
    TrayIcon: TTrayIcon;
    OpenItem, LogItem: TMenuItem;
    MainSeparator: TMenuItem;
    StartItem: TMenuItem;
    SelectItem: TMenuItem;
    DiagnosticItem, SettingsItem: TMenuItem;
    TestSeparator: TMenuItem;
    AlarmItem: TMenuItem;
    ReminderItem: TMenuItem;
    ClearItem: TMenuItem;
    ExitSeparator, AboutItem: TMenuItem;
    ExitItem: TMenuItem;
    Clock: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure CommandClick(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure GearClick(Sender: TObject);
    procedure TrayOpen(Sender: TObject);
    procedure Tick(Sender: TObject);
  private
    Screens: TList;
    EventLog: TfEventLog;
    ActiveTrayIcon, InactiveTrayIcon: TIcon;
    SoundStream: TResourceStream;
    IDs: TStringList;
    Job: TApiJob;
    UpdateJob: TUpdateJob;
    PendingVersion: string;
    NextUpdateCheck: QWord;
    ApplyingUpdate: Boolean;
    Base, Token, RegionID, RegionName: string;
    Running, AlarmActive: Boolean;
    AutoStart, NextCheck, LastReminder, HideAt: QWord;
    procedure RefreshStatus;
    procedure CheckForUpdate(NowMS: QWord);
    procedure Start;
    procedure Request(const Kind: string);
    procedure ReadConfig;
    procedure ImportLegacyConfig;
    procedure EditSettings;
    procedure ShowAbout;
    procedure SaveConfig;
    procedure SelectRegions(Data: TJSONData);
    procedure ApplyAlerts(Data: TJSONData; NowMS: QWord);
    procedure PlayAlertSound(const ResourceName: string);
    procedure Notify(const Sound, Picture, EventText: string);
    procedure ClearScreens;
    procedure Report(const Msg: string);
  public
    destructor Destroy; override;
  end;

var
  fMainForm: TfMainForm;

implementation

{$R *.lfm}
{$R alertassets.res}

const
  SettingsKey = 'Software\AlertPro';
  WindowsRunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  WindowsRunName = 'AlertPro';
  StartupShortcutName = 'Alert Pro.lnk';
  WindowsRunFlag = '--windows-startup';

procedure TApiJob.Execute;
var HTTP: OleVariant;
begin
  CoInitialize(nil);
  try
    try
      HTTP := CreateOleObject('WinHttp.WinHttpRequest.5.1');
      HTTP.SetTimeouts(5000, 5000, 5000, 10000);
      HTTP.Open('GET', WideString('https://api.ukrainealarm.com/api/v3/' + Kind), False);
      HTTP.Option[6] := False;
      HTTP.SetRequestHeader('Authorization', WideString(UTF8Decode(Token)));
      HTTP.SetRequestHeader('User-Agent', 'STETHENN_PRO_LAZARUS');
      HTTP.Send;
      if Integer(HTTP.Status) <> 200 then
        raise Exception.CreateFmt('HTTP %d', [Integer(HTTP.Status)]);
      Data := GetJSON(UTF8Encode(UnicodeString(HTTP.ResponseText)));
    except
      on E: Exception do ErrorText := E.Message;
    end;
  finally
    HTTP := Unassigned;
    CoUninitialize;
  end;
end;

destructor TApiJob.Destroy;
begin
  inherited Destroy;
  Data.Free;
end;

function Field(Data: TJSONData; const Name: string): TJSONData;
begin
  Result := nil;
  if Data is TJSONObject then Result := TJSONObject(Data).Find(Name);
end;

function Value(Data: TJSONData; const Name: string): string;
var Item: TJSONData;
begin
  Item := Field(Data, Name);
  if Assigned(Item) and (Item.JSONType in [jtString, jtNumber]) then
    Result := Item.AsString
  else Result := '';
end;

procedure LoadTrayIcon(Icon: TIcon; const ResourceName: string);
var Stream: TResourceStream;
begin
  Stream := TResourceStream.Create(HInstance, ResourceName, RT_RCDATA);
  try
    Icon.LoadFromStream(Stream);
  finally
    Stream.Free;
  end;
end;

function ReadText(const Path: string): string;
var Stream: TFileStream;
begin
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then Stream.ReadBuffer(Result[1], Length(Result));
  finally
    Stream.Free;
  end;
  if Copy(Result, 1, 3) = #$EF#$BB#$BF then Delete(Result, 1, 3);
end;

procedure TfMainForm.FormCreate(Sender: TObject);
const AutoStartSeconds = 5;
begin
  Base := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  IDs := TStringList.Create;
  IDs.Sorted := True;
  IDs.Duplicates := dupIgnore;
  Screens := TList.Create;
  EventLog := TfEventLog.Create(Self);
  EventLog.LoadHistory(Base + 'alertpro.log');
  ReadConfig;
  Caption := 'Alert Pro';
  NextUpdateCheck := GetTickCount64 + 3600000;
  if (ParamCount > 0) and SameText(ParamStr(1), WindowsRunFlag) then
    if not SetPriorityClass(GetCurrentProcess, HIGH_PRIORITY_CLASS) then
      Report(Format('Не вдалося встановити високий пріоритет (Windows %d)', [GetLastError]));
  RegionLabel.Caption := RegionName;
  AutoStart := GetTickCount64 + AutoStartSeconds * 1000;
  Status.Caption := Format('Автозапуск через %d с', [AutoStartSeconds]);
  Icon.Assign(Application.Icon);
  ActiveTrayIcon := TIcon.Create;
  InactiveTrayIcon := TIcon.Create;
  ActiveTrayIcon.Assign(Application.Icon);
  InactiveTrayIcon.Assign(Application.Icon);
  try
    LoadTrayIcon(ActiveTrayIcon, 'ALERT_TRAY_ACTIVE');
    LoadTrayIcon(InactiveTrayIcon, 'ALERT_TRAY_INACTIVE');
  except
    on E: Exception do Report(Format('Помилка завантаження іконки трея: %s', [E.Message]));
  end;
  RefreshStatus;
  TrayIcon.Visible := True;
  Clock.Enabled := True;
  if WasUpdateInstalled then
    Report(Format('Alert Pro оновлено до версії %s', [AlertProVersion]));
end;

destructor TfMainForm.Destroy;
begin
  if Assigned(Clock) then Clock.Enabled := False;
  Job.Free;
  if Assigned(UpdateJob) then
  begin
    UpdateJob.Terminate;
    UpdateJob.WaitFor;
    UpdateJob.Free;
  end;
  if not ApplyingUpdate then DeleteFileUTF8(UpdateStagePath);
  if Assigned(Screens) then ClearScreens;
  Screens.Free;
  IDs.Free;
  ActiveTrayIcon.Free;
  InactiveTrayIcon.Free;
  MMSystem.PlaySoundW(nil, 0, 0);
  SoundStream.Free;
  inherited Destroy;
end;

procedure TfMainForm.Report(const Msg: string);
begin
  EventLog.AddEvent(Msg);
end;

procedure TfMainForm.ReadConfig;
var R: TRegistry;
begin
  RegionID := '26';
  RegionName := 'Чернівецька обл. (Повний контроль)';
  IDs.CommaText := '26,137,138,139';
  R := TRegistry.Create(KEY_READ);
  try
    try
      R.RootKey := HKEY_CURRENT_USER;
      if R.OpenKeyReadOnly(SettingsKey) then
      begin
        if R.ValueExists('APIKEY') then Token := Trim(R.ReadString('APIKEY'));
        if R.ValueExists('MAIN_REGION_ID') then RegionID := R.ReadString('MAIN_REGION_ID');
        if R.ValueExists('REGION_NAME_TEXT') then RegionName := R.ReadString('REGION_NAME_TEXT');
        if R.ValueExists('MONITOR_LIST') then IDs.CommaText := R.ReadString('MONITOR_LIST');
        IDs.Add(RegionID);
      end
      else
        ImportLegacyConfig;
    except
      on E: Exception do Report(Format('Помилка читання налаштувань: %s', [E.Message]));
    end;
  finally
    R.Free;
  end;
end;

procedure TfMainForm.ImportLegacyConfig;
var Data, Items: TJSONData;
    I: Integer;
    S: string;
begin
  if not FileExists(Base + 'config.json') then Exit;
  Data := GetJSON(ReadText(Base + 'config.json'));
  try
    if not (Data is TJSONObject) then raise Exception.Create('Очікується об’єкт JSON');
    Token := Trim(Value(Data, 'APIKEY'));
    S := Value(Data, 'MAIN_REGION_ID');
    if S <> '' then RegionID := S;
    S := Value(Data, 'REGION_NAME_TEXT');
    if S <> '' then RegionName := S;
    Items := Field(Data, 'MONITOR_LIST');
    if Items is TJSONArray then
    begin
      IDs.Clear;
      for I := 0 to Items.Count - 1 do
        if Items.Items[I].JSONType in [jtString, jtNumber] then
          IDs.Add(Items.Items[I].AsString);
    end;
    IDs.Add(RegionID);
    SaveConfig;
  finally
    Data.Free;
  end;
end;

procedure TfMainForm.SaveConfig;
var R: TRegistry;
begin
  R := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    R.RootKey := HKEY_CURRENT_USER;
    if not R.OpenKey(SettingsKey, True) then
      raise Exception.Create('Не вдалося відкрити налаштування Alert Pro в реєстрі');
    R.WriteString('APIKEY', Token);
    R.WriteString('MAIN_REGION_ID', RegionID);
    R.WriteString('REGION_NAME_TEXT', RegionName);
    R.WriteString('MONITOR_LIST', IDs.CommaText);
  finally
    R.Free;
  end;
end;

procedure TfMainForm.EditSettings;
var Dialog: TfSettings;
    R: TRegistry;
    Shell, Shortcut: OleVariant;
    StartupDir, ShortcutPath, PreviousToken: string;
begin
  Dialog := TfSettings.Create(Self);
  R := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    try
      Shell := CreateOleObject('WScript.Shell');
      StartupDir := UTF8Encode(UnicodeString(Shell.SpecialFolders.Item('Startup')));
      if StartupDir = '' then
        raise Exception.Create('Не вдалося знайти папку автозавантаження Windows');
      ShortcutPath := IncludeTrailingPathDelimiter(StartupDir) + StartupShortcutName;

      R.RootKey := HKEY_CURRENT_USER;
      Dialog.ApiKeyEdit.Text := Token;
      Dialog.StartWithWindows.Checked := FileExistsUTF8(ShortcutPath);
      if R.OpenKeyReadOnly(WindowsRunKey) then
        if R.ValueExists(WindowsRunName) then Dialog.StartWithWindows.Checked := True;
      R.CloseKey;
      if Dialog.ShowModal <> mrOk then Exit;

      if Dialog.StartWithWindows.Checked then
      begin
        Shortcut := Shell.CreateShortcut(WideString(UTF8Decode(ShortcutPath)));
        Shortcut.TargetPath := WideString(UTF8Decode(ParamStr(0)));
        Shortcut.WorkingDirectory := WideString(UTF8Decode(Base));
        Shortcut.Arguments := WideString(WindowsRunFlag);
        Shortcut.Description := 'Alert Pro';
        Shortcut.Save;
        if not FileExistsUTF8(ShortcutPath) then
          raise Exception.Create('Не вдалося створити ярлик автозапуску');
      end
      else if FileExistsUTF8(ShortcutPath) then
        if not DeleteFileUTF8(ShortcutPath) then
          raise Exception.Create('Не вдалося видалити ярлик автозапуску');

      // Remove the previous Run entry so Windows launches only the shortcut.
      if R.OpenKey(WindowsRunKey, False) and R.ValueExists(WindowsRunName) then
        if not R.DeleteValue(WindowsRunName) then
          raise Exception.Create('Не вдалося видалити попередній запис автозапуску');

      PreviousToken := Token;
      Token := Trim(Dialog.ApiKeyEdit.Text);
      try
        SaveConfig;
      except
        Token := PreviousToken;
        raise;
      end;
      if Token <> PreviousToken then NextCheck := GetTickCount64;
      Report('Налаштування збережено');
    except
      on E: Exception do
      begin
        Report(Format('Помилка збереження налаштувань: %s', [E.Message]));
        MessageDlg('Не вдалося зберегти налаштування', E.Message, mtError, [mbOK], 0);
      end;
    end;
  finally
    R.Free;
    Dialog.Free;
  end;
end;

procedure TfMainForm.SelectRegions(Data: TJSONData);
var Dialog: TForm; StatesBox, DistrictsBox: TListBox; OK, Cancel: TButton;
    States, Districts, Item, Children: TJSONData;
    I, J: Integer; S, Names: string; Selected: Boolean;
  procedure AddID(Node: TJSONData);
  var ID: string;
  begin
    if Node is TJSONObject then ID := Value(Node, 'regionId')
    else if Node.JSONType in [jtNumber, jtString] then ID := Node.AsString
    else ID := '';
    if ID <> '' then IDs.Add(ID);
  end;
begin
  States := Field(Data, 'states');
  if not (States is TJSONArray) or (States.Count = 0) then
    raise Exception.Create('API не повернув список областей');
  Dialog := TForm.CreateNew(Self);
  try
    Dialog.Caption := 'Виберіть область';
    Dialog.BorderStyle := bsDialog;
    Dialog.Position := poScreenCenter;
    Dialog.ClientWidth := 480;
    Dialog.ClientHeight := 340;
    StatesBox := TListBox.Create(Dialog);
    StatesBox.Parent := Dialog;
    StatesBox.SetBounds(12,12,456,275);
    for I := 0 to States.Count - 1 do StatesBox.Items.Add(Value(States.Items[I], 'regionName'));
    StatesBox.ItemIndex := 0;
    OK := TButton.Create(Dialog);
    OK.Parent := Dialog;
    OK.SetBounds(260,298,100,30);
    OK.Caption := 'Далі';
    OK.Default := True;
    OK.ModalResult := mrOk;
    Cancel := TButton.Create(Dialog);
    Cancel.Parent := Dialog;
    Cancel.SetBounds(368,298,100,30);
    Cancel.Caption := 'Скасувати';
    Cancel.Cancel := True;
    Cancel.ModalResult := mrCancel;
    if (Dialog.ShowModal <> mrOk) or (StatesBox.ItemIndex < 0) then Exit;
    Item := States.Items[StatesBox.ItemIndex];
    S := Value(Item, 'regionId');
    if S = '' then raise Exception.Create('Відсутній ID області');
    Districts := Field(Item, 'districts');
    if not (Districts is TJSONArray) or (Districts.Count = 0) then
      Districts := Field(Item, 'regionChildIds');
    StatesBox.Hide;
    Dialog.Caption := 'Райони · порожній вибір охоплює всю область';
    OK.Caption := 'Зберегти';
    DistrictsBox := TListBox.Create(Dialog);
    DistrictsBox.Parent := Dialog;
    DistrictsBox.SetBounds(12,12,456,275);
    DistrictsBox.MultiSelect := True;
    if Districts is TJSONArray then
      for I := 0 to Districts.Count - 1 do
      begin
        if Districts.Items[I] is TJSONObject then
          Names := Value(Districts.Items[I], 'regionName')
        else Names := Districts.Items[I].AsJSON;
        DistrictsBox.Items.Add(Names);
      end;
    if Dialog.ShowModal <> mrOk then Exit;
    RegionID := S;
    RegionName := Value(Item, 'regionName');
    IDs.Clear;
    IDs.Add(RegionID);
    Selected := DistrictsBox.SelCount > 0;
    Names := '';
    for I := 0 to DistrictsBox.Items.Count - 1 do
      if not Selected or DistrictsBox.Selected[I] then
      begin
        Item := Districts.Items[I];
        AddID(Item);
        Children := Field(Item, 'communities');
        if Children is TJSONArray then
          for J := 0 to Children.Count - 1 do AddID(Children.Items[J]);
        if Names <> '' then Names := Names + ', ';
        Names := Names + DistrictsBox.Items[I];
      end;
    if not Selected then Names := 'Вся область';
    RegionName := RegionName + ' (' + Names + ')';
    RegionLabel.Caption := RegionName;
    SaveConfig;
    Start;
  finally
    Dialog.Free;
  end;
end;

procedure TfMainForm.ClearScreens;
var I: Integer;
begin
  for I := Screens.Count - 1 downto 0 do TForm(Screens[I]).Free;
  Screens.Clear;
  HideAt := 0;
end;

procedure TfMainForm.PlayAlertSound(const ResourceName: string);
begin
  MMSystem.PlaySoundW(nil, 0, 0);
  FreeAndNil(SoundStream);
  try
    SoundStream := TResourceStream.Create(HInstance, ResourceName, RT_RCDATA);
    // Asynchronous playback needs the resource buffer until the sound stops.
    if not MMSystem.PlaySoundW(PWideChar(SoundStream.Memory), 0,
      SND_MEMORY or SND_ASYNC or SND_NODEFAULT) then
    begin
      FreeAndNil(SoundStream);
      Report(Format('Не вдалося відтворити звук: %s', [ResourceName]));
    end;
  except
    on E: Exception do Report(Format('Помилка звукового ресурсу %s: %s', [ResourceName, E.Message]));
  end;
end;

procedure TfMainForm.Notify(const Sound, Picture, EventText: string);
var
  I: Integer;
  W: TForm;
  Img: TImage;
  Bounds: TRect;
  Stream: TResourceStream;
  Artwork: TPortableNetworkGraphic;
begin
  Report(EventText);
  PlayAlertSound(Sound);
  if Picture = '' then Exit;
  ClearScreens;
  try
    Artwork := TPortableNetworkGraphic.Create;
    try
      Stream := TResourceStream.Create(HInstance, Picture, RT_RCDATA);
      try
        Artwork.LoadFromStream(Stream);
      finally
        Stream.Free;
      end;
      for I := 0 to Screen.MonitorCount - 1 do
      begin
        W := TForm.CreateNew(Self);
        Screens.Add(W);
        W.BorderStyle := bsNone;
        W.FormStyle := fsStayOnTop;
        W.ShowInTaskBar := stNever;
        Img := TImage.Create(W);
        Img.Parent := W;
        Img.Align := alClient;
        Img.Stretch := True;
        Img.Proportional := True;
        Img.Center := True;
        Img.Picture.Assign(Artwork);
        Bounds := Screen.Monitors[I].BoundsRect;
        W.Width := Img.Picture.Width;
        W.Height := Img.Picture.Height;
        if W.Width > Bounds.Right - Bounds.Left then W.Width := Bounds.Right - Bounds.Left;
        if W.Height > Bounds.Bottom - Bounds.Top then W.Height := Bounds.Bottom - Bounds.Top;
        W.Left := Bounds.Left + (Bounds.Right - Bounds.Left - W.Width) div 2;
        W.Top := Bounds.Top + (Bounds.Bottom - Bounds.Top - W.Height) div 2;
        W.Show;
      end;
      HideAt := GetTickCount64 + 15000;
    finally
      Artwork.Free;
    end;
  except
    on E: Exception do
    begin
      ClearScreens;
      Report('Помилка зображення: ' + E.Message);
    end;
  end;
end;

procedure TfMainForm.ApplyAlerts(Data: TJSONData; NowMS: QWord);
var I: Integer; Item, Alerts: TJSONData; Red: Boolean; ID: string;
begin
  if not (Data is TJSONArray) then raise Exception.Create('Некоректний список тривог');
  Red := False;
  for I := 0 to Data.Count - 1 do
  begin
    Item := Data.Items[I];
    ID := Value(Item, 'regionId');
    Alerts := Field(Item, 'activeAlerts');
    if (ID = '') or not (Alerts is TJSONArray) then
      raise Exception.Create('Некоректний запис тривоги');
    if (IDs.IndexOf(ID) >= 0) and (Alerts.Count > 0) then Red := True;
  end;
  ApiLabel.Caption := 'API: Ок';
  ApiLabel.Font.Color := TColor(11068803);
  if Red then Status.Caption := 'Повітряна тривога'
  else Status.Caption := 'Тривоги немає';
  if Red and not AlarmActive then
  begin
    Notify('ALERT_SOUND_ALARM', 'ALERT_IMAGE_WARNING', 'Повітряна тривога');
    LastReminder := NowMS;
  end
  else if Red and (NowMS - LastReminder >= 1800000) then
  begin
    Notify('ALERT_SOUND_REMINDER', '', 'Нагадування: повітряна тривога триває');
    LastReminder := NowMS;
  end
  else if AlarmActive and not Red then
    Notify('ALERT_SOUND_CLEAR', 'ALERT_IMAGE_CLEAR', 'Відбій повітряної тривоги');
  AlarmActive := Red;
end;

procedure TfMainForm.Request(const Kind: string);
begin
  if Assigned(Job) then Exit;
  if Token = '' then
  begin
    Status.Caption := 'Потрібен ключ Ukraine Alarm API';
    ApiLabel.Caption := 'Помилка з''єднання з АПІ';
    ApiLabel.Font.Color := TColor(10462975);
    Report('Введіть ключ API в меню «Налаштування»');
    Running := False;
    StartItem.Caption := 'Запустити моніторинг';
    Exit;
  end;
  Job := TApiJob.Create(True);
  Job.Token := Token;
  Job.Kind := Kind;
  if Kind = 'diagnostic' then Job.Kind := 'alerts';
  Job.Diagnostic := Kind = 'diagnostic';
  Job.Start;
end;

procedure TfMainForm.Start;
begin
  Running := True;
  StartItem.Caption := 'Зупинити моніторинг';
  Status.Caption := 'Очікування відповіді API';
  NextCheck := GetTickCount64;
end;

procedure TfMainForm.ShowAbout;
var Dialog: TfAbout;
begin
  Dialog := TfAbout.Create(Self);
  try
    Dialog.ShowModal;
  finally
    Dialog.Free;
  end;
end;

procedure TfMainForm.CommandClick(Sender: TObject);
begin
  case TMenuItem(Sender).Tag of
    0: Application.Terminate;
    1: begin
         AutoStart := 0;
         if Running then
         begin
           Running := False;
           StartItem.Caption := 'Запустити моніторинг';
           Status.Caption := 'Моніторинг зупинено';
         end
         else Start;
       end;
    2: Request('regions');
    3: Notify('ALERT_SOUND_ALARM', 'ALERT_IMAGE_WARNING', 'Тест: сирена');
    4: Notify('ALERT_SOUND_REMINDER', '', 'Тест: нагадування');
    5: Notify('ALERT_SOUND_CLEAR', 'ALERT_IMAGE_CLEAR', 'Тест: відбій');
    6: begin
         TrayOpen(Sender);
         if not Assigned(Job) then
         begin
           ApiLabel.Caption := 'Перевіряємо АПІ…';
           ApiLabel.Font.Color := TColor(16766624);
           Request('diagnostic');
         end;
       end;
    8: TrayOpen(Sender);
    10: EditSettings;
    11: ShowAbout;
    9: begin
         EventLog.Show;
         EventLog.BringToFront;
       end;
  end;
  RefreshStatus;
end;

procedure TfMainForm.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction := caHide;
end;

procedure TfMainForm.GearClick(Sender: TObject);
var P: TPoint;
begin
  P.X := 0;
  P.Y := GearButton.Height;
  P := GearButton.ClientToScreen(P);
  OpenItem.Enabled := False;
  try
    SettingsMenu.PopUp(P.X, P.Y);
  finally
    OpenItem.Enabled := True;
  end;
end;

procedure TfMainForm.TrayOpen(Sender: TObject);
begin
  Show;
  BringToFront;
end;

procedure TfMainForm.RefreshStatus;
var StateText: string;
begin
  if Running then
  begin
    StateText := 'Активно';
  end
  else
  begin
    StateText := 'Неактивно';
  end;
  if Status.Caption = 'Повітряна тривога' then
    Status.Font.Color := TColor($009FA6FF)
  else if Status.Caption = 'Тривоги немає' then
    Status.Font.Color := TColor($00A8E583)
  else
    Status.Font.Color := TColor($00FFD6A0);
  if TrayIcon.Hint <> 'ALERT PRO · ' + StateText then
  begin
    if Running then TrayIcon.Icon.Assign(ActiveTrayIcon)
    else TrayIcon.Icon.Assign(InactiveTrayIcon);
    TrayIcon.Hint := 'ALERT PRO · ' + StateText;
  end;
end;

procedure TfMainForm.CheckForUpdate(NowMS: QWord);
begin
  if Assigned(UpdateJob) then
  begin
    if not UpdateJob.Finished then Exit;
    try
      if UpdateJob.ErrorText <> '' then
        Report(Format('Помилка оновлення: %s', [UpdateJob.ErrorText]))
      else if UpdateJob.Version <> '' then
      begin
        PendingVersion := UpdateJob.Version;
        Report(Format('Завантажено оновлення %s', [PendingVersion]));
      end;
    finally
      FreeAndNil(UpdateJob);
    end;
  end;

  if PendingVersion <> '' then
  begin
    if (AutoStart <> 0) or Assigned(Job) or (HideAt <> 0) or (Application.ModalLevel <> 0) then Exit;
    if Running and (AlarmActive or (ApiLabel.Caption <> 'API: Ок') or
      (Status.Caption <> 'Тривоги немає')) then Exit;
    try
      LaunchUpdateHelper;
      ApplyingUpdate := True;
      Application.Terminate;
    except
      on E: Exception do
      begin
        Report(Format('Не вдалося встановити оновлення: %s', [E.Message]));
        DeleteFileUTF8(UpdateStagePath);
        PendingVersion := '';
      end;
    end;
    Exit;
  end;

  if NowMS < NextUpdateCheck then Exit;
  NextUpdateCheck := NowMS + 3600000;
  UpdateJob := TUpdateJob.Create(True);
  UpdateJob.StagePath := UpdateStagePath;
  UpdateJob.Start;
end;

procedure TfMainForm.Tick(Sender: TObject);
var MS: QWord; FinishedJob: TApiJob;
begin
  MS := GetTickCount64;
  if (HideAt <> 0) and (MS >= HideAt) then ClearScreens;
  if AutoStart <> 0 then
    if MS >= AutoStart then
    begin
      AutoStart := 0;
      Start;
    end
    else Status.Caption := Format('Автозапуск через %d с', [(AutoStart-MS+999) div 1000]);
  if Assigned(Job) and Job.Finished then
  begin
    FinishedJob := Job;
    Job := nil;
    Clock.Enabled := False;
    try
      try
        if FinishedJob.ErrorText <> '' then raise Exception.Create(FinishedJob.ErrorText);
        if FinishedJob.Kind = 'regions' then SelectRegions(FinishedJob.Data)
        else if FinishedJob.Diagnostic then
        begin
          if not (FinishedJob.Data is TJSONArray) then raise Exception.Create('Некоректна відповідь API');
          ApiLabel.Caption := 'API: Ок';
          ApiLabel.Font.Color := TColor(11068803);
          Report('Ukraine Alarm API відповідає');
        end
        else if Running then ApplyAlerts(FinishedJob.Data, MS);
      except
        on E: Exception do
        begin
          Report('Помилка: ' + E.Message);
          ApiLabel.Caption := 'Помилка з''єднання з АПІ';
          ApiLabel.Font.Color := TColor(10462975);
        end;
      end;
    finally
      FinishedJob.Free;
      Clock.Enabled := True;
    end;
  end;
  SelectItem.Enabled := not Assigned(Job);
  DiagnosticItem.Enabled := not Assigned(Job);
  if Running and not Assigned(Job) and (MS >= NextCheck) then
  begin
    NextCheck := MS + 20000;
    Request('alerts');
  end;
  CheckForUpdate(MS);
  RefreshStatus;
end;

end.