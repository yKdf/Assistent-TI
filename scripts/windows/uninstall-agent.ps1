#Requires -RunAsAdministrator
param([switch]$RemoveData)
$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:ProgramData 'AssistenteTI'
$task = Get-ScheduledTask -TaskName AssistenteTIUpdate -ErrorAction SilentlyContinue
if ($task) {
    Disable-ScheduledTask -TaskName AssistenteTIUpdate | Out-Null
    Stop-ScheduledTask -TaskName AssistenteTIUpdate
    Unregister-ScheduledTask -TaskName AssistenteTIUpdate -Confirm:$false
}
$service = Get-Service AssistenteTINode -ErrorAction SilentlyContinue
if ($service) {
    Stop-Service AssistenteTINode
    $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
    & sc.exe delete AssistenteTINode | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao remover o serviço.' }
}
if ($RemoveData) {
    $resolved = [IO.Path]::GetFullPath($installDir)
    $expected = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'AssistenteTI'))
    if ($resolved -ne $expected -or (Get-Item -LiteralPath $resolved).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { throw 'Pasta de instalação inesperada.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'Agente removido. Revogue também a credencial deste computador no painel do servidor.'
if (!$RemoveData) { Write-Host "Dados mantidos em $installDir. Use -RemoveData para removê-los antes de um novo cadastro." }
