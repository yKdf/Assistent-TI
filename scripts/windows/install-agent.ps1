#Requires -RunAsAdministrator
param(
    [string]$Server,
    [string]$UpdatePublicKey,
    [string]$RustDeskId,
    [switch]$AllowReboot,
    [string]$Binary = "$PSScriptRoot\..\..\dist\windows\assist-agent.exe"
)
$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:ProgramData 'AssistenteTI'
if (Get-Service AssistenteTINode -ErrorAction SilentlyContinue) { throw 'O agente já está instalado. Use atualização assinada ou desinstale antes de recadastrar.' }
if (Test-Path -LiteralPath $installDir) { throw 'A pasta AssistenteTI já existe. Revise e remova a instalação anterior antes de prosseguir; o instalador não reutiliza pastas preexistentes.' }
if (!(Test-Path -LiteralPath $Binary)) { throw "Binário não encontrado: $Binary. Execute scripts/build-windows.ps1 primeiro." }
if (!$Server) { $Server = Read-Host 'URL HTTPS do servidor (ex.: https://ti.empresa.com)' }
$serverUri = [uri]$Server
if (!$serverUri.IsAbsoluteUri -or ($serverUri.Scheme -ne 'https' -and !($serverUri.Scheme -eq 'http' -and $serverUri.IsLoopback))) { throw 'Use HTTPS ou localhost.' }
if ($serverUri.UserInfo -or $serverUri.Query -or $serverUri.Fragment -or $serverUri.AbsolutePath -ne '/') { throw 'Informe apenas a origem do servidor.' }
if (!$UpdatePublicKey) { $UpdatePublicKey = Read-Host 'Chave pública de atualização (64 caracteres hex; vazio desabilita atualizações)' }
if ($UpdatePublicKey -and $UpdatePublicKey -notmatch '^[a-fA-F0-9]{64}$') { throw 'Chave pública inválida.' }
if (!$RustDeskId) { $RustDeskId = Read-Host 'ID RustDesk deste computador (opcional, apenas números)' }
$RustDeskId = $RustDeskId -replace ' ', ''
if ($RustDeskId -and $RustDeskId -notmatch '^\d{1,20}$') { throw 'ID RustDesk inválido.' }
$invite = Read-Host 'Convite de uso único gerado no painel (válido por 15 minutos)'
if ($invite -notmatch '^[a-fA-F0-9]{64}$') { throw 'Convite inválido.' }
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
# ACL por SID funciona em Windows em português e em inglês. Usuários comuns não podem alterar o agente.
& icacls.exe $installDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Não foi possível proteger a pasta do agente.' }
Copy-Item -LiteralPath $Binary -Destination (Join-Path $installDir 'assist-agent.exe') -Force
Copy-Item -LiteralPath "$PSScriptRoot\update-agent.ps1" -Destination $installDir -Force
Copy-Item -LiteralPath "$PSScriptRoot\uninstall-agent.ps1" -Destination $installDir -Force
$config = @{
    server = $Server.TrimEnd('/'); node_id = ''; token = ''; allow_reboot = [bool]$AllowReboot;
    support_id = $(if ($RustDeskId) { $RustDeskId } else { $null });
    update_public_key = $(if ($UpdatePublicKey) { $UpdatePublicKey } else { $null }); installed_sequence = 0
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $installDir 'config.json'), ($config | ConvertTo-Json), $utf8)
$enrollProcess = New-Object System.Diagnostics.Process
$enrollProcess.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
$enrollProcess.StartInfo.FileName = Join-Path $installDir 'assist-agent.exe'
$enrollProcess.StartInfo.Arguments = 'enroll'
$enrollProcess.StartInfo.UseShellExecute = $false
$enrollProcess.StartInfo.CreateNoWindow = $true
$enrollProcess.StartInfo.RedirectStandardInput = $true
$enrollProcess.StartInfo.EnvironmentVariables['ASSIST_AGENT_DIR'] = $installDir
$enrollProcess.Start() | Out-Null
$enrollProcess.StandardInput.WriteLine($invite)
$enrollProcess.StandardInput.Close()
$invite = $null
$enrollProcess.WaitForExit()
if ($enrollProcess.ExitCode -ne 0) { throw 'Cadastro falhou. Corrija a conexão, remova a configuração sem credenciais e tente com novo convite.' }
New-Service -Name AssistenteTINode -BinaryPathName ('"' + (Join-Path $installDir 'assist-agent.exe') + '" service') -DisplayName 'Assistente TI — Node' -Description 'Inventário e suporte autorizado da organização.' -StartupType Automatic | Out-Null
& sc.exe failure AssistenteTINode reset= 86400 actions= restart/10000/restart/30000/restart/60000 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Não foi possível configurar recuperação de falhas.' }
& sc.exe failureflag AssistenteTINode 1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Não foi possível habilitar recuperação de erros do serviço.' }
# SYSTEM e administradores podem controlar; usuários autenticados podem consultar, mas não parar.
& sc.exe sdset AssistenteTINode 'D:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Não foi possível definir as permissões do serviço.' }
if ($UpdatePublicKey) {
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "' + (Join-Path $installDir 'update-agent.ps1') + '"')
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2)
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName AssistenteTIUpdate -Action $action -Trigger $trigger -Settings $settings -User SYSTEM -RunLevel Highest -Force | Out-Null
}
Start-Service AssistenteTINode
Write-Host "Agente instalado em $installDir. Confira o computador no painel."
Write-Host 'Administradores podem parar e remover o serviço. Atualizações dependem de releases assinadas publicadas no servidor.'
