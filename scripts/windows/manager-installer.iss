; Build with scripts/build-manager-installer.ps1. The application remains Rust.
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef ProjectRoot
  #define ProjectRoot "..\.."
#endif

[Setup]
AppId={{E62CCB6B-5410-4839-BAA0-35C93C2259EE}
AppName=Assistente TI Manager
AppVersion={#AppVersion}
AppPublisher=Assistente TI
AppPublisherURL=https://github.com/yKdf/Assistent-TI
AppSupportURL=https://github.com/yKdf/Assistent-TI/issues
AppUpdatesURL=https://github.com/yKdf/Assistent-TI/releases
DefaultDirName={localappdata}\Programs\AssistenteTI
DefaultGroupName=Assistente TI
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
WizardStyle=modern
DisableProgramGroupPage=yes
AllowNoIcons=yes
OutputDir={#ProjectRoot}\dist
OutputBaseFilename=AssistenteTI-Manager-Setup-{#AppVersion}-windows-x64
Compression=lzma2
SolidCompression=yes
UninstallDisplayIcon={app}\assist-manager.exe
SetupLogging=yes
CloseApplications=yes
VersionInfoDescription=Instalador do Assistente TI Manager

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Tasks]
Name: "desktopicon"; Description: "Criar atalho na área de trabalho"; Flags: unchecked

[Files]
Source: "{#ProjectRoot}\target\release\assist-manager.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Assistente TI"; Filename: "{app}\assist-manager.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Assistente TI"; Filename: "{app}\assist-manager.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\assist-manager.exe"; Description: "Abrir Assistente TI"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{app}\server-url.txt"
Type: files; Name: "{app}\server-url.tmp"

[Code]
var
  ServerPage: TInputQueryWizardPage;
  CheckerExtracted: Boolean;

function CheckServer: Boolean;
var
  ExitCode: Integer;
  Server: String;
begin
  Result := False;
  Server := Trim(ServerPage.Values[0]);
  if (Server = '') or (Pos('"', Server) > 0) or (Pos(#13, Server) > 0) or (Pos(#10, Server) > 0) then
    Exit;
  if not CheckerExtracted then
  begin
    ExtractTemporaryFile('assist-manager.exe');
    CheckerExtracted := True;
  end;
  Result := Exec(ExpandConstant('{tmp}\assist-manager.exe'), '--check-server "' + Server + '"',
    '', SW_HIDE, ewWaitUntilTerminated, ExitCode) and (ExitCode = 0);
end;

function EdgeInstalled: Boolean;
begin
  Result := FileExists(ExpandConstant('{pf32}\Microsoft\Edge\Application\msedge.exe')) or
    FileExists(ExpandConstant('{pf64}\Microsoft\Edge\Application\msedge.exe')) or
    FileExists(ExpandConstant('{localappdata}\Microsoft\Edge\Application\msedge.exe'));
end;

procedure InitializeWizard;
var
  Server: String;
  Saved: AnsiString;
begin
  ServerPage := CreateInputQueryPage(wpSelectDir, 'Conectar ao seu servidor',
    'Informe o endereço da central Assistente TI.',
    'Use a URL HTTPS do servidor da sua organização. O aplicativo usa o Microsoft Edge para abrir o painel em uma janela própria.');
  ServerPage.Add('Endereço do servidor:', False);
  Server := ExpandConstant('{param:SERVERURL|}');
  if Server = '' then
    if LoadStringFromFile(ExpandConstant('{localappdata}\Programs\AssistenteTI\server-url.txt'), Saved) then
      Server := String(Saved);
  if Server = '' then
    Server := GetPreviousData('ServerUrl', 'https://');
  ServerPage.Values[0] := Server;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = ServerPage.ID then
  begin
    Result := CheckServer;
    if (not Result) and (not WizardSilent) then
      MsgBox('Informe uma URL válida, por exemplo https://ti.suaempresa.com.br. Não inclua senha, caminho ou parâmetros. HTTP é permitido somente em localhost.', mbError, MB_OK);
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not CheckServer then
    Result := 'URL do servidor inválida. Em instalação silenciosa, informe /SERVERURL=https://ti.suaempresa.com.br.'
  else if not EdgeInstalled then
    Result := 'Instale o Microsoft Edge antes de instalar o Assistente TI Manager.';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ExitCode: Integer;
begin
  if CurStep = ssPostInstall then
    if not Exec(ExpandConstant('{app}\assist-manager.exe'), '--configure "' + Trim(ServerPage.Values[0]) + '"',
      '', SW_HIDE, ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then
      RaiseException('Não foi possível salvar a configuração do servidor. Execute o instalador novamente.');
end;

procedure RegisterPreviousData(PreviousDataKey: Integer);
begin
  SetPreviousData(PreviousDataKey, 'ServerUrl', Trim(ServerPage.Values[0]));
end;
