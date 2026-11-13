param([string]$BinDir = "$PSScriptRoot\..\target\release", [switch]$Browser)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$runDir = Join-Path $root ('test-output\smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$runDir\server","$runDir\agent" -Force | Out-Null
$server = $null
$agent = $null
$chrome = $null
$socket = $null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$password = [guid]::NewGuid().ToString('N')
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$listener.Stop()
$url = "http://127.0.0.1:$port"
$headers = @{'X-Assist-Client'='1'}
$oldData = $env:ASSIST_DATA
$oldPassword = $env:ASSIST_ADMIN_PASSWORD_FILE
$oldBind = $env:ASSIST_BIND
$oldPublic = $env:ASSIST_PUBLIC_URL
$oldAgentDir = $env:ASSIST_AGENT_DIR
function Assert([bool]$condition,[string]$message) { if (!$condition) { throw $message } }
function Api([string]$path, $body = $null) {
    if ($null -eq $body) { return Invoke-RestMethod "$url/api$path" -Headers $headers -WebSession $script:session }
    return Invoke-RestMethod "$url/api$path" -Method Post -Headers $headers -WebSession $script:session -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 10 -Compress)
}
$script:messageId = 0
function Cdp([string]$method, $parameters = @{}) {
    $script:messageId++
    $payload = @{id=$script:messageId;method=$method;params=$parameters} | ConvertTo-Json -Depth 20 -Compress
    $buffer = [Text.Encoding]::UTF8.GetBytes($payload)
    $segment = [ArraySegment[byte]]::new($buffer)
    $socket.SendAsync($segment,[Net.WebSockets.WebSocketMessageType]::Text,$true,[Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    $timeout = New-Object Threading.CancellationTokenSource(20000)
    try {
        do {
            $stream = New-Object IO.MemoryStream
            do {
                $receive = New-Object byte[] 65536
                $result = $socket.ReceiveAsync([ArraySegment[byte]]::new($receive),$timeout.Token).GetAwaiter().GetResult()
                $stream.Write($receive,0,$result.Count)
            } while (!$result.EndOfMessage)
            $message = [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
            $stream.Dispose()
            if ($message.method -eq 'Runtime.exceptionThrown') { throw ($message.params.exceptionDetails | ConvertTo-Json -Depth 5) }
        } while ($message.id -ne $script:messageId)
        if ($message.error) { throw ($message.error | ConvertTo-Json) }
        return $message.result
    } finally { $timeout.Dispose() }
}
try {
    $keyOutput = & "$BinDir\assist-release.exe" keygen "$runDir\test-signing.key"
    Assert ($LASTEXITCODE -eq 0) 'Geração da chave de teste falhou.'
    $publicKey = [regex]::Match(($keyOutput -join ''),'[a-f0-9]{64}').Value
    Assert ($publicKey.Length -eq 64) 'Chave pública de teste ausente.'
    $version = & "$BinDir\assist-agent.exe" version
    & "$BinDir\assist-release.exe" sign "$runDir\test-signing.key" "$BinDir\assist-agent.exe" $version 1 "$runDir\server\releases"
    Assert ($LASTEXITCODE -eq 0) 'Assinatura da release de teste falhou.'
    [IO.File]::WriteAllText("$runDir\password",$password,$utf8)
    $env:ASSIST_DATA = "$runDir\server"
    $env:ASSIST_ADMIN_PASSWORD_FILE = "$runDir\password"
    $env:ASSIST_BIND = "127.0.0.1:$port"
    $env:ASSIST_PUBLIC_URL = $url
    $server = Start-Process -FilePath "$BinDir\assist-server.exe" -WindowStyle Hidden -PassThru -RedirectStandardOutput "$runDir\server.log" -RedirectStandardError "$runDir\server-error.log"
    for ($i=0; $i -lt 30; $i++) {
        try { $health = Invoke-RestMethod "$url/health"; break } catch { Start-Sleep -Milliseconds 500 }
    }
    Assert ($health.status -eq 'ok') 'Servidor não iniciou.'
    Invoke-RestMethod "$url/api/login" -Method Post -Headers $headers -ContentType 'application/json' -Body (@{password=$password}|ConvertTo-Json) -SessionVariable session | Out-Null
    Assert (@((Api '/nodes').nodes).Count -eq 0) 'Banco deveria começar vazio.'
    $invite = Api '/invites' @{}
    $env:ASSIST_AGENT_DIR = "$runDir\agent"
    [IO.File]::WriteAllText("$runDir\agent\config.json",(@{server=$url;node_id='';token='';allow_reboot=$false;support_id=$null;update_public_key=$publicKey;installed_sequence=0}|ConvertTo-Json),$utf8)
    $invite.code | & "$BinDir\assist-agent.exe" enroll
    Assert ($LASTEXITCODE -eq 0) 'Cadastro real do agente falhou.'
    $agent = Start-Process -FilePath "$BinDir\assist-agent.exe" -ArgumentList 'run' -WindowStyle Hidden -PassThru -RedirectStandardOutput "$runDir\agent-console.log" -RedirectStandardError "$runDir\agent-error.log"
    $node = $null
    for ($i=0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        $node = (Api '/nodes').nodes | Select-Object -First 1
        if ($node.online) { break }
    }
    Assert ($node.online) 'Agente não enviou heartbeat.'
    Assert ($node.metrics.memory_total -gt 0) 'Métricas reais de memória ausentes.'
    Assert ($node.metrics.processes.Count -gt 0) 'Processos reais ausentes.'
    $command = Api "/nodes/$($node.id)/commands" @{action='refresh'}
    for ($i=0; $i -lt 45; $i++) {
        Start-Sleep -Seconds 1
        $result = (Api '/activity').commands | Where-Object id -eq $command.id
        if ($result.status -eq 'completed') { break }
    }
    Assert ($result.status -eq 'completed') 'Comando de inventário não confirmou conclusão.'
    Assert (Test-Path "$runDir\agent\pending.json") 'Agente não preparou a atualização assinada.'
    & "$BinDir\assist-agent.exe" verify-update
    Assert ($LASTEXITCODE -eq 0) 'Verificação da atualização pendente falhou.'
    Copy-Item -LiteralPath "$runDir\agent\pending.json" -Destination "$runDir\agent\installing.json"
    & "$BinDir\assist-agent.exe" verify-update
    Assert ($LASTEXITCODE -eq 0) 'Verificação final da atualização falhou.'
    if ($Browser) {
        $chromePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
        Assert (Test-Path $chromePath) 'Chrome indisponível para teste de interface.'
        $chromeArgs = @('--headless=new','--disable-background-networking','--no-first-run','--no-default-browser-check','--remote-debugging-port=0',('--user-data-dir="' + "$runDir\chrome" + '"'),'about:blank')
        $chrome = Start-Process -FilePath $chromePath -ArgumentList $chromeArgs -WindowStyle Hidden -PassThru -RedirectStandardError "$runDir\chrome.log"
        for ($i=0; $i -lt 40; $i++) {
            if (Test-Path "$runDir\chrome\DevToolsActivePort") { break }
            Start-Sleep -Milliseconds 250
        }
        $debugPort = (Get-Content "$runDir\chrome\DevToolsActivePort")[0]
        $page = $null
        for ($i=0; $i -lt 40; $i++) {
            $pages = Invoke-RestMethod "http://127.0.0.1:$debugPort/json/list"
            $page = $pages | Where-Object type -eq 'page' | Select-Object -First 1
            if ($page.webSocketDebuggerUrl) { break }
            Start-Sleep -Milliseconds 250
        }
        Assert ([bool]$page.webSocketDebuggerUrl) 'Página do Chrome não ficou disponível.'
        $socket = New-Object Net.WebSockets.ClientWebSocket
        $socket.ConnectAsync([uri]$page.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
        Cdp 'Runtime.enable' | Out-Null
        Cdp 'Page.enable' | Out-Null
        Cdp 'Emulation.setDeviceMetricsOverride' @{width=1440;height=1000;deviceScaleFactor=1;mobile=$false} | Out-Null
        Cdp 'Page.navigate' @{url=$url} | Out-Null
        Start-Sleep -Seconds 2
        $passwordJson = ConvertTo-Json $password -Compress
        Cdp 'Runtime.evaluate' @{expression="document.getElementById('password').value=$passwordJson;document.getElementById('login-form').requestSubmit();"} | Out-Null
        Start-Sleep -Seconds 2
        $visible = Cdp 'Runtime.evaluate' @{expression="!document.getElementById('workspace').hidden && document.querySelectorAll('#nodes tr').length===1";returnByValue=$true}
        Assert ($visible.result.value -eq $true) 'Login e listagem no navegador falharam.'
        $shot = Cdp 'Page.captureScreenshot' @{format='png';captureBeyondViewport=$false}
        [IO.File]::WriteAllBytes("$runDir\dashboard.png",[Convert]::FromBase64String($shot.data))
        Cdp 'Runtime.evaluate' @{expression="document.querySelector('[data-node]').click()"} | Out-Null
        $details = Cdp 'Runtime.evaluate' @{expression="document.getElementById('detail-dialog').open && document.querySelectorAll('#processes tr').length>0";returnByValue=$true}
        Assert ($details.result.value -eq $true) 'Detalhes dos processos no navegador falharam.'
        Cdp 'Runtime.evaluate' @{expression="document.getElementById('detail-dialog').close();document.getElementById('add-node').click()"} | Out-Null
        Start-Sleep -Seconds 1
        $modal = Cdp 'Runtime.evaluate' @{expression="document.getElementById('enroll-dialog').open && document.getElementById('invite-code').value.length===64";returnByValue=$true}
        Assert ($modal.result.value -eq $true) 'Convite no navegador falhou.'
        Cdp 'Runtime.evaluate' @{expression="document.getElementById('enroll-dialog').close();document.querySelector('[data-view=activity]').click()"} | Out-Null
        Start-Sleep -Seconds 1
        $activity = Cdp 'Runtime.evaluate' @{expression="!document.getElementById('activity-view').hidden && document.querySelectorAll('#commands .event').length>0";returnByValue=$true}
        Assert ($activity.result.value -eq $true) 'Histórico no navegador falhou.'
        Cdp 'Emulation.setDeviceMetricsOverride' @{width=390;height=844;deviceScaleFactor=1;mobile=$true} | Out-Null
        Cdp 'Runtime.evaluate' @{expression="document.querySelector('[data-view=fleet]').click()"} | Out-Null
        $mobile = Cdp 'Runtime.evaluate' @{expression="document.documentElement.scrollWidth <= 390";returnByValue=$true}
        Assert ($mobile.result.value -eq $true) 'Layout mobile apresenta overflow.'
        $shot = Cdp 'Page.captureScreenshot' @{format='png';captureBeyondViewport=$false}
        [IO.File]::WriteAllBytes("$runDir\mobile.png",[Convert]::FromBase64String($shot.data))
    }
    Api "/nodes/$($node.id)/revoke" @{} | Out-Null
    Assert (!((Api '/nodes').nodes | Select-Object -First 1).enabled) 'Revogação falhou.'
    [IO.File]::WriteAllText("$runDir\result.json", (@{passed=$true;browser=[bool]$Browser;version=$version;time=(Get-Date -Format o);checks=@('enrollment','telemetry','processes','refresh-command','signed-release','revocation','browser-if-enabled')} | ConvertTo-Json), $utf8)
    Write-Output "SMOKE OK: servidor, cadastro, métricas, processos, comando, resultado, release assinada e revogação. Browser=$Browser"
    Write-Output "Artefatos: $runDir"
} finally {
    if ($socket) {
        try { Cdp 'Browser.close' | Out-Null } catch { }
        $socket.Dispose()
    }
    foreach ($ownedProcess in @($chrome,$agent,$server)) {
        if ($ownedProcess -and !$ownedProcess.HasExited) { Stop-Process -Id $ownedProcess.Id -Force }
    }
    $env:ASSIST_DATA = $oldData
    $env:ASSIST_ADMIN_PASSWORD_FILE = $oldPassword
    $env:ASSIST_BIND = $oldBind
    $env:ASSIST_PUBLIC_URL = $oldPublic
    $env:ASSIST_AGENT_DIR = $oldAgentDir
    if (Test-Path "$runDir\password") { Remove-Item -LiteralPath "$runDir\password" -Force }
    if (Test-Path "$runDir\test-signing.key") { Remove-Item -LiteralPath "$runDir\test-signing.key" -Force }
}
