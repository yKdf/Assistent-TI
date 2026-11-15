; Unified Windows installer. The applications remain native Rust binaries.
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef ProjectRoot
  #define ProjectRoot "..\.."
#endif

[Setup]
AppId={{E62CCB6B-5410-4839-BAA0-35C93C2259EE}
AppName=Assistente TI
AppVersion={#AppVersion}
AppPublisher=Assistente TI
AppPublisherURL=https://github.com/yKdf/Assistent-TI
AppSupportURL=https://github.com/yKdf/Assistent-TI/issues
AppUpdatesURL=https://github.com/yKdf/Assistent-TI/releases
DefaultDirName={localappdata}\Programs\AssistenteTI
DefaultGroupName=Assistente TI
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
WizardStyle=modern
DisableProgramGroupPage=yes
AllowNoIcons=yes
OutputDir={#ProjectRoot}\dist
OutputBaseFilename=AssistenteTI-Setup-{#AppVersion}-windows-x64
Compression=lzma2
SolidCompression=yes
UninstallDisplayIcon={app}\assist-manager.exe
SetupLogging=yes
CloseApplications=yes
UsedUserAreasWarning=no
VersionInfoDescription=Instalador unificado do Assistente TI

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Types]
Name: "manager"; Description: "Somente Manager"
Name: "full"; Description: "Manager, Agente e Servidor"
Name: "custom"; Description: "Personalizado — escolher componentes"; Flags: iscustom

[Components]
Name: "manager"; Description: "Manager — painel de gerenciamento"; Types: manager full custom
Name: "agent"; Description: "Agente — computador gerenciado"; Types: full
Name: "server"; Description: "Servidor — central e painel web"; Types: full

[Tasks]
Name: "desktopicon"; Description: "Criar atalho do Manager na área de trabalho"; Flags: unchecked; Components: manager

[Files]
Source: "{#ProjectRoot}\target\release\assist-manager.exe"; DestDir: "{app}"; Flags: ignoreversion; Components: manager
Source: "{#ProjectRoot}\target\release\assist-manager.exe"; Flags: dontcopy
Source: "{#ProjectRoot}\target\release\assist-agent.exe"; Flags: dontcopy
Source: "{#ProjectRoot}\target\release\assist-support.exe"; Flags: dontcopy
Source: "{#ProjectRoot}\target\release\assist-server.exe"; Flags: dontcopy
Source: "{#ProjectRoot}\scripts\windows\install-agent.ps1"; Flags: dontcopy
Source: "{#ProjectRoot}\scripts\windows\upgrade-agent.ps1"; Flags: dontcopy
Source: "{#ProjectRoot}\scripts\windows\update-agent.ps1"; Flags: dontcopy
Source: "{#ProjectRoot}\scripts\windows\uninstall-agent.ps1"; DestDir: "{app}\support"; Flags: ignoreversion; Components: agent
Source: "{#ProjectRoot}\scripts\windows\uninstall-agent.ps1"; Flags: dontcopy
Source: "{#ProjectRoot}\scripts\windows\install-server.ps1"; Flags: dontcopy
Source: "{#ProjectRoot}\scripts\windows\run-server.ps1"; Flags: dontcopy
Source: "{#ProjectRoot}\scripts\windows\uninstall-server.ps1"; DestDir: "{app}\support"; Flags: ignoreversion; Components: server
Source: "{#ProjectRoot}\scripts\windows\uninstall-server.ps1"; Flags: dontcopy

[Icons]
Name: "{autoprograms}\Assistente TI"; Filename: "{app}\assist-manager.exe"; WorkingDir: "{app}"; Components: manager
Name: "{autodesktop}\Assistente TI"; Filename: "{app}\assist-manager.exe"; WorkingDir: "{app}"; Tasks: desktopicon; Components: manager

[Run]
Filename: "{app}\assist-manager.exe"; Description: "Abrir Assistente TI"; Flags: nowait postinstall skipifsilent; Components: manager

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File ""{app}\support\uninstall-agent.ps1"""; Flags: runhidden waituntilterminated; Components: agent; RunOnceId: "RemoveAgent"
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File ""{app}\support\uninstall-server.ps1"""; Flags: runhidden waituntilterminated; Components: server; RunOnceId: "RemoveServer"

[UninstallDelete]
Type: files; Name: "{app}\server-url.txt"
Type: files; Name: "{app}\server-url.tmp"

[Code]
var
  ConnectionPage, AgentPage, ServerPage: TInputQueryWizardPage;
  CheckerExtracted: Boolean;

function Selected(const Name: String): Boolean;
begin
  Result := WizardIsComponentSelected(Name);
end;

function SafeValue(const Value: String): Boolean;
begin
  Result := (Pos('"', Value) = 0) and (Pos(#13, Value) = 0) and (Pos(#10, Value) = 0);
end;

procedure ExtractSupportFiles;
begin
  ExtractTemporaryFile('assist-manager.exe');
  ExtractTemporaryFile('assist-agent.exe');
  ExtractTemporaryFile('assist-support.exe');
  ExtractTemporaryFile('assist-server.exe');
  ExtractTemporaryFile('install-agent.ps1');
  ExtractTemporaryFile('upgrade-agent.ps1');
  ExtractTemporaryFile('update-agent.ps1');
  ExtractTemporaryFile('uninstall-agent.ps1');
  ExtractTemporaryFile('install-server.ps1');
  ExtractTemporaryFile('run-server.ps1');
  ExtractTemporaryFile('uninstall-server.ps1');
end;

function CheckConnectionUrl: Boolean;
var
  ExitCode: Integer;
  Value: String;
begin
  Value := Trim(ConnectionPage.Values[0]);
  Result := SafeValue(Value) and (Value <> '');
  if not Result then Exit;
  if not CheckerExtracted then begin ExtractTemporaryFile('assist-manager.exe'); CheckerExtracted := True; end;
  Result := Exec(ExpandConstant('{tmp}\assist-manager.exe'), '--check-server "' + Value + '"', '', SW_HIDE, ewWaitUntilTerminated, ExitCode) and (ExitCode = 0);
end;

function EdgeInstalled: Boolean;
begin
  Result := FileExists(ExpandConstant('{pf32}\Microsoft\Edge\Application\msedge.exe')) or FileExists(ExpandConstant('{pf64}\Microsoft\Edge\Application\msedge.exe')) or FileExists(ExpandConstant('{localappdata}\Microsoft\Edge\Application\msedge.exe'));
end;

function AgentInstalled: Boolean;
begin
  Result := FileExists(ExpandConstant('{commonappdata}\AssistenteTI\config.json')) and FileExists(ExpandConstant('{commonappdata}\AssistenteTI\assist-agent.exe'));
end;

procedure InitializeWizard;
var
  Saved: AnsiString;
begin
  ConnectionPage := CreateInputQueryPage(wpSelectComponents, 'Conexão com a central', 'Configuração do Manager e do Agente', 'Informe a URL HTTPS usada pelos computadores para acessar o servidor.');
  ConnectionPage.Add('URL do servidor:', False);
  ConnectionPage.Values[0] := ExpandConstant('{param:SERVERURL|}');
  if ConnectionPage.Values[0] = '' then if LoadStringFromFile(ExpandConstant('{localappdata}\Programs\AssistenteTI\server-url.txt'), Saved) then ConnectionPage.Values[0] := String(Saved);
  if ConnectionPage.Values[0] = '' then ConnectionPage.Values[0] := GetPreviousData('ServerUrl', 'https://');

  AgentPage := CreateInputQueryPage(ConnectionPage.ID, 'Configurar Agente', 'Cadastre este computador como node', 'Gere um convite de uso único no painel. Os demais campos são opcionais.');
  AgentPage.Add('Convite de uso único:', False);
  AgentPage.Add('Chave pública de atualização (hex):', False);
  AgentPage.Values[0] := ExpandConstant('{param:INVITE|}');
  AgentPage.Values[1] := ExpandConstant('{param:UPDATEKEY|}');

  ServerPage := CreateInputQueryPage(AgentPage.ID, 'Configurar Servidor', 'Central Assistente TI no Windows', 'O servidor será iniciado automaticamente. Use a URL pública HTTPS se houver proxy externo.');
  ServerPage.Add('Escutar em:', False);
  ServerPage.Add('URL pública (opcional):', False);
  ServerPage.Add('Senha administrativa (mínimo 12 caracteres):', True);
  ServerPage.Values[0] := ExpandConstant('{param:SERVERBIND|0.0.0.0:80}');
  ServerPage.Values[1] := ExpandConstant('{param:PUBLICURL|}');
  ServerPage.Values[2] := ExpandConstant('{param:ADMINPASSWORD|}');
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := ((PageID = ConnectionPage.ID) and not (Selected('manager') or (Selected('agent') and not AgentInstalled))) or ((PageID = AgentPage.ID) and (not Selected('agent') or AgentInstalled)) or ((PageID = ServerPage.ID) and not Selected('server'));
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = ConnectionPage.ID) and not CheckConnectionUrl then begin MsgBox('Informe uma URL HTTPS válida. HTTP é aceito somente em localhost.', mbError, MB_OK); Result := False; end
  else if (CurPageID = AgentPage.ID) and not AgentInstalled and ((Length(Trim(AgentPage.Values[0])) <> 64) or not SafeValue(AgentPage.Values[0]) or not SafeValue(AgentPage.Values[1])) then begin MsgBox('Informe um convite válido e confira os demais campos.', mbError, MB_OK); Result := False; end
  else if (CurPageID = ServerPage.ID) and ((Length(ServerPage.Values[2]) < 12) or not SafeValue(ServerPage.Values[0]) or not SafeValue(ServerPage.Values[1])) then begin MsgBox('Confira o endereço e informe uma senha de pelo menos 12 caracteres.', mbError, MB_OK); Result := False; end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if (Selected('manager') or (Selected('agent') and not AgentInstalled)) and not CheckConnectionUrl then Result := 'URL do servidor inválida.'
  else if Selected('manager') and not EdgeInstalled then Result := 'Instale o Microsoft Edge antes de instalar o Manager.'
  else if Selected('agent') and not AgentInstalled and (Length(Trim(AgentPage.Values[0])) <> 64) then Result := 'O Agente precisa de um convite válido.'
  else if Selected('agent') and not AgentInstalled and DirExists(ExpandConstant('{commonappdata}\AssistenteTI')) then Result := 'Existe uma pasta incompleta do Agente sem serviço válido. Revise ou remova C:\ProgramData\AssistenteTI antes de instalar.'
  else if Selected('server') and (Length(ServerPage.Values[2]) < 12) then Result := 'O Servidor precisa de senha administrativa com ao menos 12 caracteres.';
end;

procedure RunPowerShell(const Script, Parameters: String);
var
  ExitCode: Integer;
  ErrorFile: String;
  ErrorText: AnsiString;
begin
  ErrorFile := ExpandConstant('{tmp}\component-error.txt');
  DeleteFile(ErrorFile);
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "' + ExpandConstant('{tmp}\' + Script) + '" ' + Parameters + ' -ErrorFile "' + ErrorFile + '"', '', SW_HIDE, ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then begin
    if LoadStringFromFile(ErrorFile, ErrorText) and (Trim(String(ErrorText)) <> '') then
      RaiseException('Falha ao instalar o componente:' + #13#10 + Trim(String(ErrorText)))
    else
      RaiseException('Falha ao instalar o componente. Código: ' + IntToStr(ExitCode));
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ExitCode: Integer;
  SecretFile, Parameters: String;
begin
  if CurStep <> ssPostInstall then Exit;
  ExtractSupportFiles;
  if Selected('manager') then if not Exec(ExpandConstant('{app}\assist-manager.exe'), '--configure "' + Trim(ConnectionPage.Values[0]) + '"', '', SW_HIDE, ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then RaiseException('Não foi possível configurar o Manager.');
  if Selected('server') then begin
    SecretFile := ExpandConstant('{tmp}\server-password.txt');
    SaveStringToFile(SecretFile, ServerPage.Values[2], False);
    Parameters := '-Bind "' + Trim(ServerPage.Values[0]) + '" -PasswordFile "' + SecretFile + '" -Binary "' + ExpandConstant('{tmp}\assist-server.exe') + '"';
    if Trim(ServerPage.Values[1]) <> '' then Parameters := Parameters + ' -PublicUrl "' + Trim(ServerPage.Values[1]) + '"';
    RunPowerShell('install-server.ps1', Parameters);
    DeleteFile(SecretFile);
  end;
  if Selected('agent') then begin
    if AgentInstalled then begin
      Parameters := '-Binary "' + ExpandConstant('{tmp}\assist-agent.exe') + '" -SupportBinary "' + ExpandConstant('{tmp}\assist-support.exe') + '"';
      if Trim(AgentPage.Values[1]) <> '' then Parameters := Parameters + ' -UpdatePublicKey "' + Trim(AgentPage.Values[1]) + '"';
      RunPowerShell('upgrade-agent.ps1', Parameters);
    end else begin
      SecretFile := ExpandConstant('{tmp}\agent-invite.txt');
      SaveStringToFile(SecretFile, Trim(AgentPage.Values[0]), False);
      Parameters := '-InstallerMode -Server "' + Trim(ConnectionPage.Values[0]) + '" -InviteFile "' + SecretFile + '" -Binary "' + ExpandConstant('{tmp}\assist-agent.exe') + '" -SupportBinary "' + ExpandConstant('{tmp}\assist-support.exe') + '"';
      if Trim(AgentPage.Values[1]) <> '' then Parameters := Parameters + ' -UpdatePublicKey "' + Trim(AgentPage.Values[1]) + '"';
      RunPowerShell('install-agent.ps1', Parameters);
      DeleteFile(SecretFile);
    end;
  end;
end;

procedure RegisterPreviousData(PreviousDataKey: Integer);
begin
  if Selected('manager') or Selected('agent') then SetPreviousData(PreviousDataKey, 'ServerUrl', Trim(ConnectionPage.Values[0]));
end;
