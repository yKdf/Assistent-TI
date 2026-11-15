#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)][string]$Binary,
    [Parameter(Mandatory=$true)][string]$SupportBinary,
    [string]$UpdatePublicKey,
    [string]$ErrorFile
)
$ErrorActionPreference = 'Stop'
trap {
    if ($ErrorFile) { [IO.File]::WriteAllText($ErrorFile, ($_ | Out-String), (New-Object Text.UTF8Encoding($false))) }
    if ($installDir) {
        $backup = Join-Path $installDir 'assist-agent.installer-backup.exe'
        if (Test-Path -LiteralPath $backup) { Copy-Item -LiteralPath $backup -Destination (Join-Path $installDir 'assist-agent.exe') -Force -ErrorAction SilentlyContinue }
    }
    $service = Get-Service AssistenteTINode -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Stopped') { Start-Service AssistenteTINode -ErrorAction SilentlyContinue }
    exit 1
}
$installDir = Join-Path $env:ProgramData 'AssistenteTI'
$supportDir = Join-Path $env:ProgramData 'AssistenteTISupport'
$configPath = Join-Path $installDir 'config.json'
$service = Get-Service AssistenteTINode -ErrorAction Stop
if (!(Test-Path $configPath) -or !(Test-Path $Binary) -or !(Test-Path $SupportBinary)) { throw 'Arquivos necessários para atualizar o Agente não foram encontrados.' }
if ($service.Status -ne 'Stopped') { Stop-Service AssistenteTINode; $service.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(60)) }
$currentBinary = Join-Path $installDir 'assist-agent.exe'
Copy-Item -LiteralPath $currentBinary -Destination (Join-Path $installDir 'assist-agent.installer-backup.exe') -Force
Copy-Item -LiteralPath $Binary -Destination $currentBinary -Force
Copy-Item -LiteralPath "$PSScriptRoot\update-agent.ps1" -Destination $installDir -Force
Copy-Item -LiteralPath "$PSScriptRoot\uninstall-agent.ps1" -Destination $installDir -Force
if ($UpdatePublicKey) {
    if ($UpdatePublicKey -notmatch '^[a-fA-F0-9]{64}$') { throw 'Chave pública de atualização inválida.' }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $config.update_public_key = $UpdatePublicKey
    [IO.File]::WriteAllText($configPath,($config|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
}
New-Item -ItemType Directory -Path $supportDir -Force | Out-Null
$env:ASSIST_AGENT_DIR = $installDir
$env:ASSIST_SUPPORT_CONFIG = Join-Path $supportDir 'config.json'
& $currentBinary provision-support
if ($LASTEXITCODE -ne 0) { throw 'O servidor não emitiu a credencial de suporte. Atualize o servidor antes do Agente.' }
Get-Process assist-support -ErrorAction SilentlyContinue | Stop-Process -Force
Copy-Item -LiteralPath $SupportBinary -Destination (Join-Path $supportDir 'assist-support.exe') -Force
& icacls.exe $supportDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-11:(OI)(CI)RX' /t | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Não foi possível proteger o módulo de suporte.' }
New-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name AssistenteTISupport -PropertyType String -Value ('"' + (Join-Path $supportDir 'assist-support.exe') + '"') -Force | Out-Null
Start-Service AssistenteTINode
Start-Process -FilePath (Join-Path $supportDir 'assist-support.exe') -WindowStyle Hidden
Write-Host 'Agente e módulo de suporte atualizados; cadastro e configurações foram preservados.'
