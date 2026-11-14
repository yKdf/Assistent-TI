#Requires -RunAsAdministrator
param(
    [string]$Bind = '0.0.0.0:80',
    [string]$PublicUrl,
    [Parameter(Mandatory=$true)][string]$PasswordFile,
    [string]$Binary = "$PSScriptRoot\..\..\target\release\assist-server.exe"
)
$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:ProgramData 'AssistenteTIServer'
if (!(Test-Path -LiteralPath $Binary)) { throw "Binário não encontrado: $Binary" }
$listenUri = [uri]('tcp://' + $Bind)
$listenAddress = $null
if (!$listenUri.IsAbsoluteUri -or ![Net.IPAddress]::TryParse($listenUri.DnsSafeHost, [ref]$listenAddress) -or $listenUri.Port -lt 1 -or $listenUri.Port -gt 65535) { throw 'Endereço de escuta inválido.' }
if ($PublicUrl) {
    $uri = [uri]$PublicUrl
    if (!$uri.IsAbsoluteUri -or @('http','https') -notcontains $uri.Scheme -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') { throw 'URL pública inválida.' }
}
if (!(Test-Path -LiteralPath $PasswordFile)) { throw 'Arquivo temporário da senha não encontrado.' }
$password = [IO.File]::ReadAllText($PasswordFile).Trim()
if ($password.Length -lt 12) { throw 'A senha administrativa deve ter ao menos 12 caracteres.' }
New-Item -ItemType Directory -Path $installDir,(Join-Path $installDir 'data') -Force | Out-Null
& icacls.exe $installDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Não foi possível proteger a pasta do servidor.' }
$existingTask = Get-ScheduledTask -TaskName AssistenteTIServer -ErrorAction SilentlyContinue
if ($existingTask) { Stop-ScheduledTask -TaskName AssistenteTIServer -ErrorAction SilentlyContinue }
Copy-Item -LiteralPath $Binary -Destination (Join-Path $installDir 'assist-server.exe') -Force
Copy-Item -LiteralPath "$PSScriptRoot\run-server.ps1" -Destination $installDir -Force
Copy-Item -LiteralPath "$PSScriptRoot\uninstall-server.ps1" -Destination $installDir -Force
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $installDir 'admin-password'), $password, $utf8)
[IO.File]::WriteAllText((Join-Path $installDir 'server.json'), (@{bind=$Bind;public_url=$PublicUrl} | ConvertTo-Json), $utf8)
$password = $null
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "' + (Join-Path $installDir 'run-server.ps1') + '"')
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
Register-ScheduledTask -TaskName AssistenteTIServer -Action $action -Trigger $trigger -Settings $settings -User SYSTEM -RunLevel Highest -Force | Out-Null
Remove-NetFirewallRule -Name AssistenteTIServer -ErrorAction SilentlyContinue
New-NetFirewallRule -Name AssistenteTIServer -DisplayName 'Assistente TI Server' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $listenUri.Port | Out-Null
Start-ScheduledTask -TaskName AssistenteTIServer
$healthHost = $listenUri.DnsSafeHost
if ($healthHost -eq '0.0.0.0') { $healthHost = '127.0.0.1' }
if ($healthHost -eq '::') { $healthHost = '[::1]' }
$healthy = $false
for ($attempt = 0; $attempt -lt 15; $attempt++) {
    Start-Sleep -Seconds 1
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri ("http://${healthHost}:$($listenUri.Port)/health") -TimeoutSec 2
        if ($response.StatusCode -eq 200) { $healthy = $true; break }
    } catch {}
}
if (!$healthy) { throw "O servidor não respondeu na porta $($listenUri.Port). Verifique se a porta já está ocupada." }
Write-Host "Servidor instalado em $installDir e configurado para iniciar com o Windows."
