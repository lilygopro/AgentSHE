# Emergency AV restore — GPO/policy only. Run elevated (or self-elevates).
# Uses SYSTEM task to delete Tamper-locked Policies\Windows Defender keys.
$ErrorActionPreference = 'SilentlyContinue'
try { $PSNativeCommandUseErrorActionPreference = $false } catch {}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
  $self = $MyInvocation.MyCommand.Path
  if ($self) {
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
      -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$self`""
    return
  }
  Write-Host 'ERROR: lance en Administrateur'
  try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 8 }
  return
}

Write-Host '1) Stop EarlyAV / HelperHost'
$kit = Join-Path $env:ProgramData 'HelperHostWipe'
if (-not (Test-Path $kit)) { New-Item -ItemType Directory -Path $kit -Force | Out-Null }
'1' | Set-Content -Encoding ASCII (Join-Path $kit 'STOP') -Force
foreach ($tn in @(
  'HelperHostEarlyAV','HelperHost','HelperHostResume','HelperHostBoot',
  'HelperHostResumeBoot','HelperHostWipeRestore','HelperHostDControlOff','HelperHostDControlOn',
  'HelperHostClearPol','AgentShePC'
)) {
  schtasks /Delete /TN $tn /F 2>$null | Out-Null
}
foreach ($n in @('HelperHost','EdgeRelay','dControl','disable-defender','enable-defender','cloudflared')) {
  Get-Process $n -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
}
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name HelperHostResume -Force -EA SilentlyContinue
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name HelperHost -Force -EA SilentlyContinue
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name AgentShePC -Force -EA SilentlyContinue

Write-Host '2) Delete org policies (SYSTEM for Tamper-locked keys)'
# Security Center first = Virus tab back (often deletable as Admin)
foreach ($rp in @(
  'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender Security Center',
  'HKLM\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows Defender Security Center'
)) { cmd /c "reg delete `"$rp`" /f" | Out-Null }

$bat = Join-Path $env:TEMP 'hh-clear-pol.cmd'
@(
  '@echo off'
  'reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" /f'
  'reg delete "HKLM\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows Defender" /f'
  'reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender Security Center" /f'
  'reg delete "HKLM\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows Defender Security Center" /f'
  'reg delete "HKLM\SOFTWARE\Policies\Microsoft\MicrosoftEdge\PhishingFilter" /f'
  'reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableSmartScreen /f'
  'reg add "HKLM\SOFTWARE\Microsoft\Windows Defender\UX Configuration" /v UILockdown /t REG_DWORD /d 0 /f'
  'reg add "HKLM\SOFTWARE\Microsoft\Windows Defender" /v DisableAntiSpyware /t REG_DWORD /d 0 /f'
  'reg delete "HKLM\SOFTWARE\Microsoft\Windows Defender Security Center\Virus and threat protection" /v UILockdown /f'
  'reg delete "HKLM\SOFTWARE\Microsoft\Windows Defender Security Center\Virus and threat protection" /v HideVirusThreatPage /f'
) -join "`r`n" | Set-Content -Encoding ASCII $bat
schtasks /Create /TN HelperHostClearPol /TR "cmd.exe /c `"$bat`"" /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F | Out-Null
schtasks /Run /TN HelperHostClearPol | Out-Null
Start-Sleep -Seconds 4
schtasks /Delete /TN HelperHostClearPol /F 2>$null | Out-Null
Remove-Item $bat -Force -EA SilentlyContinue

# SmartScreen + RTP live overrides
cmd /c 'reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v SmartScreenEnabled /t REG_SZ /d Warn /f' | Out-Null
$rtp = 'HKLM\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection'
foreach ($v in @(
  'DisableRealtimeMonitoring','DisableBehaviorMonitoring','DisableOnAccessProtection',
  'DisableScanOnRealtimeEnable','DisableIOAVProtection','DisableScriptScanning','DisableRawWriteNotification'
)) { cmd /c "reg delete `"$rtp`" /v $v /f" | Out-Null }

Write-Host '3) Services + MpPreference'
foreach ($svc in @('WinDefend','WdNisSvc','Sense','SecurityHealthService','wscsvc','webthreatdefsvc','MDCoreSvc')) {
  cmd /c "sc.exe config $svc start= auto" | Out-Null
  cmd /c "sc.exe start $svc" | Out-Null
}
if (Get-Command Set-MpPreference -EA SilentlyContinue) {
  Set-MpPreference -DisableRealtimeMonitoring $false -EA SilentlyContinue
  Set-MpPreference -DisableBehaviorMonitoring $false -EA SilentlyContinue
  Set-MpPreference -DisableIOAVProtection $false -EA SilentlyContinue
  Set-MpPreference -DisableScriptScanning $false -EA SilentlyContinue
  Set-MpPreference -UILockdown $false -EA SilentlyContinue
  Set-MpPreference -MAPSReporting Advanced -EA SilentlyContinue
  Set-MpPreference -SubmitSamplesConsent 1 -EA SilentlyContinue
}

Write-Host '4) Scrub HelperHost traces'
foreach ($p in @(
  (Join-Path $env:LOCALAPPDATA 'HelperHost'),
  (Join-Path $env:TEMP 'HelperHostCache'),
  (Join-Path $env:LOCALAPPDATA 'Temp\HelperHostCache'),
  (Join-Path $env:ProgramData 'HelperHostWipe'),
  'C:\ProgramData\defender-control'
)) {
  if (Test-Path $p) {
    cmd /c "takeown /f `"$p`" /r /d o" | Out-Null
    cmd /c "rmdir /s /q `"$p`"" | Out-Null
  }
}
Remove-Item 'HKCU:\Software\HelperHost' -Recurse -Force -EA SilentlyContinue
$hf = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
if (Test-Path $hf) {
  (Get-Content $hf | Where-Object { $_ -notmatch '# agentshe-bot' }) | Set-Content $hf -Encoding ASCII
}
Get-ChildItem $env:TEMP -Filter 'hh-*' -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue
Get-ChildItem $env:TEMP -Filter 'HelperHost-*' -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue

Write-Host '5) gpupdate + UI'
cmd /c 'gpupdate /Target:Computer /Force' | Out-Null
Get-Process SecHealthUI,SecurityHealthSystray,SystemSettings -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 2
Start-Process 'windowsdefender:'

$left = Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
Write-Host ('Policies Windows Defender encore present: ' + $left)
Write-Host 'DONE — onglet Virus + traces HelperHost.'
Write-Output 'emergency-av-restored'
try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 8 }
