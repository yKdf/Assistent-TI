#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:ProgramData 'AssistenteTI'
$pending = Join-Path $installDir 'pending.json'
$installing = Join-Path $installDir 'installing.json'
$binary = Join-Path $installDir 'assist-agent.exe'
$backup = Join-Path $installDir 'assist-agent.previous.exe'
$configPath = Join-Path $installDir 'config.json'
$configBackup = Join-Path $installDir 'config.previous.json'
$update = Join-Path $installDir 'update.exe'
$health = Join-Path $installDir 'health.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Write-UpdateLog([string]$message) {
    $log = Join-Path $installDir 'update.log'
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 1000000) { Move-Item -LiteralPath $log -Destination "$log.previous" -Force }
    Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) $message"
}
function Stop-Agent {
    $service = Get-Service AssistenteTINode
    if ($service.Status -ne 'Stopped') { Stop-Service AssistenteTINode; $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60)) }
}
# Se o computador caiu durante a troca, restaura uma instalação conhecida antes de tentar novamente.
if (Test-Path $installing) {
    if (!(Test-Path $backup) -or !(Test-Path $configBackup)) { throw 'Recuperação requer os backups da atualização. Marcador preservado para manutenção.' }
    if ((Test-Path $backup) -and (Test-Path $configBackup)) {
        Stop-Agent
        Copy-Item -LiteralPath $backup -Destination $binary -Force
        Copy-Item -LiteralPath $configBackup -Destination $configPath -Force
        $interrupted = Get-Content -LiteralPath $installing -Raw | ConvertFrom-Json
        [IO.File]::WriteAllText((Join-Path $installDir 'failed-sequence'), [string]$interrupted.sequence, $utf8)
        Start-Service AssistenteTINode
        Write-UpdateLog 'Atualização interrompida recuperada; versão anterior restaurada.'
    }
    Remove-Item -LiteralPath $installing -Force
    exit
}
if (!(Test-Path $pending)) { exit }
$oldConfig = $null
$swapped = $false
$cleanup = $false
try {
    $env:ASSIST_AGENT_DIR = $installDir
    & $binary verify-update
    if ($LASTEXITCODE -ne 0) { throw 'Assinatura, integridade ou sequência da atualização rejeitada.' }
    $release = Get-Content -LiteralPath $pending -Raw | ConvertFrom-Json
    $oldConfig = [IO.File]::ReadAllText($configPath)
    Stop-Agent
    Copy-Item -LiteralPath $binary -Destination "$backup.tmp" -Force
    [IO.File]::WriteAllText("$configBackup.tmp", $oldConfig, $utf8)
    Move-Item -LiteralPath "$backup.tmp" -Destination $backup -Force
    Move-Item -LiteralPath "$configBackup.tmp" -Destination $configBackup -Force
    # Só marca a transação depois de ambos os backups estarem prontos.
    Move-Item -LiteralPath $pending -Destination $installing
    $swapped = $true
    Copy-Item -LiteralPath $update -Destination $binary -Force
    $config = $oldConfig | ConvertFrom-Json
    $config.installed_sequence = $release.sequence
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json), $utf8)
    if (Test-Path $health) { Remove-Item -LiteralPath $health -Force }
    Start-Service AssistenteTINode
    $healthy = $false
    for ($attempt = 0; $attempt -lt 18; $attempt++) {
        Start-Sleep -Seconds 5
        if (Test-Path $health) {
            $status = Get-Content -LiteralPath $health -Raw | ConvertFrom-Json
            if ($status.version -eq $release.version -and (Get-Service AssistenteTINode).Status -eq 'Running') { $healthy = $true; break }
        }
    }
    if (!$healthy) { throw 'A nova versão não confirmou comunicação com o servidor em 90 segundos.' }
    Write-UpdateLog "Versão $($release.version), sequência $($release.sequence), instalada e verificada."
    $cleanup = $true
} catch {
    Write-UpdateLog "Falha na atualização: $($_.Exception.Message)"
    if ($swapped) {
        Stop-Agent
        Copy-Item -LiteralPath $backup -Destination $binary -Force
        [IO.File]::WriteAllText($configPath, $oldConfig, $utf8)
        [IO.File]::WriteAllText((Join-Path $installDir 'failed-sequence'), [string]$release.sequence, $utf8)
        Start-Service AssistenteTINode
        Write-UpdateLog 'Versão anterior restaurada.'
    } elseif ((Get-Service AssistenteTINode).Status -eq 'Stopped') { Start-Service AssistenteTINode }
    $cleanup = $true
    throw
} finally {
    # Arquivos exatos dentro da pasta fixa da instalação; não remove diretórios.
    if ($cleanup -and (Test-Path $installing)) { Remove-Item -LiteralPath $installing -Force }
}
