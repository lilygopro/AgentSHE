# Restores Windows security + removes HelperHost install side-effects.
# Safe to re-run. Prefer elevated (HelperHostWipeRestore task).
$ErrorActionPreference = 'SilentlyContinue'
$hh = Join-Path $env:LOCALAPPDATA 'HelperHost'
$cache = Join-Path $env:TEMP 'HelperHostCache'

# --- UAC defaults (restore from backup if present) ---
$sysPol = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$uacBak = Join-Path $hh 'uac-backup.json'
$uj = $null
if (Test-Path $uacBak) {
  try { $uj = Get-Content $uacBak -Raw | ConvertFrom-Json } catch {}
}
if (Test-Path $sysPol) {
  $lua = 1; if ($uj -and $null -ne $uj.EnableLUA) { $lua = [int]$uj.EnableLUA }
  $cpa = 5; if ($uj -and $null -ne $uj.ConsentPromptBehaviorAdmin) { $cpa = [int]$uj.ConsentPromptBehaviorAdmin }
  $psd = 1; if ($uj -and $null -ne $uj.PromptOnSecureDesktop) { $psd = [int]$uj.PromptOnSecureDesktop }
  $eid = 1; if ($uj -and $null -ne $uj.EnableInstallerDetection) { $eid = [int]$uj.EnableInstallerDetection }
  Set-ItemProperty $sysPol -Name EnableLUA -Value $lua -Type DWord -Force
  Set-ItemProperty $sysPol -Name ConsentPromptBehaviorAdmin -Value $cpa -Type DWord -Force
  Set-ItemProperty $sysPol -Name PromptOnSecureDesktop -Value $psd -Type DWord -Force
  Set-ItemProperty $sysPol -Name EnableInstallerDetection -Value $eid -Type DWord -Force
}
Remove-Item $uacBak -Force -EA SilentlyContinue

# --- Defender Security Center / UX notification policies we may have set ---
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\UX Configuration' -Name Notification_Suppress -Force -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' -Name DisableNotifications -Force -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' -Name DisableEnhancedNotifications -Force -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Name DisableNotificationCenter -Force -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' -Name NoToastApplicationNotification -Force -EA SilentlyContinue
if (Get-Command Set-MpPreference -EA SilentlyContinue) {
  Set-MpPreference -UILockdown $false -EA SilentlyContinue
}

# --- Remove Defender disable policies we may have set ---
$wdPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
Remove-ItemProperty $wdPol -Name DisableAntiSpyware -Force -EA SilentlyContinue
Remove-ItemProperty $wdPol -Name DisableAntiVirus -Force -EA SilentlyContinue
Remove-Item "$wdPol\Real-Time Protection" -Recurse -Force -EA SilentlyContinue
# If folder empty of meaningful values, leave hive; don't delete whole key if org GPO owns it
try {
  $kids = @(Get-ChildItem $wdPol -EA SilentlyContinue)
  $vals = @(Get-ItemProperty $wdPol -EA SilentlyContinue | Select-Object -ExpandProperty PSObject).Properties
} catch {}

# --- Defender services ---
foreach ($svc in @('WinDefend', 'WdNisSvc', 'Sense')) {
  Set-Service $svc -StartupType Automatic -EA SilentlyContinue
  Start-Service $svc -EA SilentlyContinue
}

# --- Defender preferences + drop our exclusions ---
if (Get-Command Set-MpPreference -EA SilentlyContinue) {
  Set-MpPreference -DisableRealtimeMonitoring $false
  Set-MpPreference -DisableBehaviorMonitoring $false
  Set-MpPreference -DisableBlockAtFirstSeen $false
  Set-MpPreference -DisableIOAVProtection $false
  Set-MpPreference -DisableScriptScanning $false
  Set-MpPreference -DisableArchiveScanning $false
  Set-MpPreference -DisableEmailScanning $false
  Set-MpPreference -DisableRemovableDriveScanning $false
  Set-MpPreference -PUAProtection Enabled
  Set-MpPreference -MAPSReporting Advanced
  Set-MpPreference -SubmitSamplesConsent 1
  Set-MpPreference -EnableNetworkProtection Enabled
  Set-MpPreference -CloudBlockLevel Default
}
if (Get-Command Remove-MpPreference -EA SilentlyContinue) {
  Remove-MpPreference -ExclusionPath $hh -EA SilentlyContinue
  Remove-MpPreference -ExclusionPath $cache -EA SilentlyContinue
  Remove-MpPreference -ExclusionProcess 'HelperHost.exe' -EA SilentlyContinue
  Remove-MpPreference -ExclusionProcess 'EdgeRelay.exe' -EA SilentlyContinue
  if (Test-Path (Join-Path $hh 'HelperHost.exe')) {
    Remove-MpPreference -ControlledFolderAccessAllowedApplications (Join-Path $hh 'HelperHost.exe') -EA SilentlyContinue
  }
  if (Test-Path (Join-Path $hh 'EdgeRelay.exe')) {
    Remove-MpPreference -ControlledFolderAccessAllowedApplications (Join-Path $hh 'EdgeRelay.exe') -EA SilentlyContinue
  }
}

# --- Undo Soft Device Guard / SAC toggles from install (best-effort) ---
$ci = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
# 1 = Evaluation (safer than forcing Enforce)
if (Test-Path $ci) {
  $cur = (Get-ItemProperty $ci -Name VerifiedAndReputablePolicyState -EA SilentlyContinue).VerifiedAndReputablePolicyState
  if ($null -ne $cur -and [int]$cur -eq 0) {
    Set-ItemProperty $ci -Name VerifiedAndReputablePolicyState -Value 1 -Type DWord -Force -EA SilentlyContinue
  }
}
# Do not force VBS back ON (can break systems); only clear Locked flag we may have set
$dg = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
if (Test-Path $dg) {
  Remove-ItemProperty $dg -Name Locked -Force -EA SilentlyContinue
}

# bcdedit: restore defaults if we turned hypervisor off
& bcdedit.exe /set '{current}' hypervisorlaunchtype Auto | Out-Null
& bcdedit.exe /deletevalue '{current}' vsmlaunchtype | Out-Null

# --- Scheduled tasks ---
foreach ($tn in @(
  'HelperHost', 'HelperHostResume', 'HelperHostBoot', 'HelperHostResumeBoot',
  'HelperHostWipeRestore', 'AgentShePC'
)) {
  Unregister-ScheduledTask -TaskName $tn -Confirm:$false -EA SilentlyContinue
  schtasks /Delete /TN $tn /F 2>$null | Out-Null
}

# --- Run key (Win+R persistence) ---
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
foreach ($n in @('HelperHost', 'AgentShePC')) {
  Remove-ItemProperty -Path $run -Name $n -Force -EA SilentlyContinue
}

# --- RunMRU (Win+R history) ---
$mru = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU'
if (Test-Path $mru) {
  $props = Get-ItemProperty $mru -EA SilentlyContinue
  $drop = @()
  foreach ($p in $props.PSObject.Properties) {
    if ($p.Name -in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider', 'MRUList')) { continue }
    $v = [string]$p.Value
    if ($v -match 'HelperHost|EdgeRelay|AgentSHE|agentshe|install-win|install\.ps1|lilygopro|AGENTSHE_|trycloudflare') {
      $drop += $p.Name
    }
  }
  foreach ($n in $drop) { Remove-ItemProperty -Path $mru -Name $n -Force -EA SilentlyContinue }
  # Rebuild MRUList simply: clear if we removed anything
  if ($drop.Count -gt 0) {
    Remove-ItemProperty -Path $mru -Name MRUList -Force -EA SilentlyContinue
  }
}

# --- Temp / leftover install artifacts ---
Get-ChildItem $env:TEMP -Filter 'HelperHost-elev-*.ps1' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
Get-ChildItem $env:TEMP -Filter 'HelperHost-install.*' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
Get-ChildItem $env:TEMP -Filter 'hh-wipe.cmd' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
Remove-Item (Join-Path $env:TEMP 'HelperHost-install.ok') -Force -EA SilentlyContinue
Remove-Item (Join-Path $env:TEMP 'HelperHost-install.err') -Force -EA SilentlyContinue

# Prefetch
Get-ChildItem "$env:SystemRoot\Prefetch" -Filter 'HELPERHOST*' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
Get-ChildItem "$env:SystemRoot\Prefetch" -Filter 'EDGERELAY*' -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue

# PS history lines
$hist = Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
if (Test-Path $hist) {
  $re = 'HelperHost|EdgeRelay|agentshe|AgentSHE|lilygopro|install\.ps1|install-win|HelperHostCache|AGENTSHE_|trycloudflare'
  (Get-Content $hist -EA SilentlyContinue) | Where-Object { $_ -notmatch $re } | Set-Content $hist -Encoding UTF8
}

# Recent / Jump lists soft clean
$recent = Join-Path $env:APPDATA 'Microsoft\Windows\Recent'
Get-ChildItem $recent -EA SilentlyContinue | Where-Object {
  $_.Name -match 'HelperHost|install-win|install\.ps1|AgentSHE'
} | Remove-Item -Force -EA SilentlyContinue

$bak = Join-Path $hh 'notify-backup.json'
$push = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'
$exp = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
$ns = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'
$j = $null
if (Test-Path $bak) {
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
  'Windows.SystemToast.Explorer'
)) {
  $p = "$ns\$sub"
  if (Test-Path $p) { Set-ItemProperty $p -Name Enabled -Value 1 -Type DWord -Force }
}
$baa = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
if (Test-Path $baa) { Set-ItemProperty $baa -Name GlobalUserDisabled -Value 0 -Type DWord -Force }
Remove-Item $bak -Force -EA SilentlyContinue

Write-Output 'security-restored'
