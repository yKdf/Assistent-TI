#Requires -RunAsAdministrator
param([switch]$RemoveData)
$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:ProgramData 'AssistenteTIServer'
$task = Get-ScheduledTask -TaskName AssistenteTIServer -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName AssistenteTIServer -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName AssistenteTIServer -Confirm:$false
}
Remove-NetFirewallRule -Name AssistenteTIServer -ErrorAction SilentlyContinue
if ($RemoveData -and (Test-Path -LiteralPath $installDir)) {
    $resolved = [IO.Path]::GetFullPath($installDir)
    $expected = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'AssistenteTIServer'))
    if ($resolved -ne $expected -or (Get-Item -LiteralPath $resolved).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { throw 'Pasta de instalação inesperada.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'Servidor removido. Os dados foram preservados, salvo quando -RemoveData foi informado.'
