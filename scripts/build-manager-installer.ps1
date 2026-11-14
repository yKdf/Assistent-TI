param([string]$Iscc, [switch]$SkipBuild)
$arguments = @{}
if ($Iscc) { $arguments.Iscc = $Iscc }
if ($SkipBuild) { $arguments.SkipBuild = $true }
& "$PSScriptRoot\build-windows-installer.ps1" @arguments
exit $LASTEXITCODE
