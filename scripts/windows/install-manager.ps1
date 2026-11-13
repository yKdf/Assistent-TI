param([Parameter(Mandatory=$true)][string]$Server,[string]$Binary = "$PSScriptRoot\..\..\dist\windows\assist-manager.exe")
$ErrorActionPreference = 'Stop'
$uri = [uri]$Server
if (!$uri.IsAbsoluteUri -or ($uri.Scheme -ne 'https' -and !($uri.Scheme -eq 'http' -and $uri.IsLoopback)) -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') { throw 'URL inválida. Use a origem HTTPS do servidor.' }
$dest = Join-Path $env:LOCALAPPDATA 'Programs\AssistenteTI'
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item -LiteralPath $Binary -Destination (Join-Path $dest 'assist-manager.exe') -Force
[IO.File]::WriteAllText((Join-Path $dest 'server-url.txt'), $uri.AbsoluteUri, (New-Object System.Text.UTF8Encoding($false)))
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Assistente TI.lnk'))
$shortcut.TargetPath = Join-Path $dest 'assist-manager.exe'
$shortcut.WorkingDirectory = $dest
$shortcut.Description = 'Central de gerenciamento Assistente TI'
$shortcut.Save()
Write-Host 'Aplicativo instalado no menu Iniciar. Requer Microsoft Edge.'
