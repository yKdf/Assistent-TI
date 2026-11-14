$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:ProgramData 'AssistenteTIServer'
$env:ASSIST_DATA = Join-Path $installDir 'data'
$env:ASSIST_ADMIN_PASSWORD_FILE = Join-Path $installDir 'admin-password'
$configuration = Get-Content -LiteralPath (Join-Path $installDir 'server.json') -Raw | ConvertFrom-Json
$env:ASSIST_BIND = [string]$configuration.bind
$env:ASSIST_PUBLIC_URL = [string]$configuration.public_url
& (Join-Path $installDir 'assist-server.exe') *>> (Join-Path $installDir 'server.log')
exit $LASTEXITCODE
