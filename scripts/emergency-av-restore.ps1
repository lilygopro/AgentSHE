# Emergency AV restore — GPO/policy only (no enable-defender.exe). Run elevated.
$ErrorActionPreference = 'SilentlyContinue'
try { $PSNativeCommandUseErrorActionPreference = $false } catch {}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
  Write-Host 'ERROR: lance en Administrateur (clic droit PowerShell -> Executer en tant qu administrateur)'
  Write-Host 'Appuie sur Entree pour fermer...'
  try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 8 }
  return
}

Write-Host '1) Stop EarlyAV / HelperHost tasks'
$kit = Join-Path $env:ProgramData 'HelperHostWipe'
if (-not (Test-Path $kit)) { New-Item -ItemType Directory -Path $kit -Force | Out-Null }
'1' | Set-Content -Encoding ASCII (Join-Path $kit 'STOP') -Force
foreach ($tn in @(
  'HelperHostEarlyAV','HelperHost','HelperHostResume','HelperHostBoot',
  'HelperHostResumeBoot','HelperHostWipeRestore','HelperHostDControlOff','HelperHostDControlOn','AgentShePC'
)) {
  schtasks /Delete /TN $tn /F 2>$null | Out-Null
}

Write-Host '2) Kill leftover tools'
foreach ($n in @('HelperHost','EdgeRelay','dControl','disable-defender','enable-defender','cloudflared')) {
  Get-Process $n -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
}

Write-Host '3) Delete ALL Defender org policies (brings back Virus tab / drops organisation)'
$paths = @(
  'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender',
  'HKLM\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows Defender',
  'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender Security Center',
  'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\UX Configuration',
  'HKLM\SOFTWARE\Policies\Microsoft\MicrosoftEdge\PhishingFilter'
)
foreach ($rp in $paths) {
  cmd /c "reg delete `"$rp`" /f" | Out-Null
}

# SmartScreen back
cmd /c 'reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableSmartScreen /f' | Out-Null
cmd /c 'reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v SmartScreenEnabled /t REG_SZ /d Warn /f' | Out-Null

# Clear live RTP overrides
$rtp = 'HKLM\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection'
foreach ($v in @(
  'DisableRealtimeMonitoring','DisableBehaviorMonitoring','DisableOnAccessProtection',
  'DisableScanOnRealtimeEnable','DisableIOAVProtection','DisableScriptScanning','DisableRawWriteNotification'
)) {
  cmd /c "reg delete `"$rtp`" /v $v /f" | Out-Null
}
cmd /c 'reg delete "HKLM\SOFTWARE\Microsoft\Windows Defender\Features" /v TamperProtection /f' | Out-Null
cmd /c 'reg delete "HKLM\SOFTWARE\Microsoft\Windows Defender\Features" /v TamperProtectionSource /f' | Out-Null
cmd /c 'reg add "HKLM\SOFTWARE\Microsoft\Windows Defender\UX Configuration" /v UILockdown /t REG_DWORD /d 0 /f' | Out-Null
cmd /c 'reg add "HKLM\SOFTWARE\Microsoft\Windows Defender" /v DisableAntiSpyware /t REG_DWORD /d 0 /f' | Out-Null

Write-Host '4) Services WinDefend auto + start'
foreach ($svc in @('WinDefend','WdNisSvc','Sense','SecurityHealthService','wscsvc','webthreatdefsvc','MDCoreSvc')) {
  cmd /c "sc.exe config $svc start= auto" | Out-Null
  cmd /c "sc.exe start $svc" | Out-Null
}
foreach ($svc in @('WdFilter','WdNisDrv','WdBoot')) {
  cmd /c "sc.exe config $svc start= system" | Out-Null
  cmd /c "sc.exe config $svc start= boot" | Out-Null
}

Write-Host '5) MpPreference ON'
if (Get-Command Set-MpPreference -EA SilentlyContinue) {
  Set-MpPreference -DisableRealtimeMonitoring $false -EA SilentlyContinue
  Set-MpPreference -DisableBehaviorMonitoring $false -EA SilentlyContinue
  Set-MpPreference -DisableIOAVProtection $false -EA SilentlyContinue
  Set-MpPreference -DisableScriptScanning $false -EA SilentlyContinue
  Set-MpPreference -MAPSReporting Advanced -EA SilentlyContinue
  Set-MpPreference -SubmitSamplesConsent 1 -EA SilentlyContinue
  Set-MpPreference -EnableNetworkProtection Enabled -EA SilentlyContinue
  Set-MpPreference -UILockdown $false -EA SilentlyContinue
  Set-MpPreference -PUAProtection Enabled -EA SilentlyContinue
}
if (Get-Command Remove-MpPreference -EA SilentlyContinue) {
  $hh = Join-Path $env:LOCALAPPDATA 'HelperHost'
  $cache = Join-Path $env:TEMP 'HelperHostCache'
  Remove-MpPreference -ExclusionPath $hh -EA SilentlyContinue
  Remove-MpPreference -ExclusionPath $cache -EA SilentlyContinue
  Remove-MpPreference -ExclusionProcess 'HelperHost.exe' -EA SilentlyContinue
  Remove-MpPreference -ExclusionProcess 'EdgeRelay.exe' -EA SilentlyContinue
  Remove-MpPreference -ExclusionProcess 'dControl.exe' -EA SilentlyContinue
  Remove-MpPreference -ExclusionProcess 'disable-defender.exe' -EA SilentlyContinue
  Remove-MpPreference -ExclusionProcess 'enable-defender.exe' -EA SilentlyContinue
}

Write-Host '6) Delete HelperHost leftovers'
$targets = @(
  (Join-Path $env:LOCALAPPDATA 'HelperHost'),
  (Join-Path $env:TEMP 'HelperHostCache'),
  (Join-Path $env:LOCALAPPDATA 'Temp\HelperHostCache'),
  (Join-Path $env:ProgramData 'HelperHostWipe'),
  'C:\ProgramData\defender-control'
)
foreach ($p in $targets) {
  if (Test-Path $p) {
    attrib -h -s /s /d "$p\*" 2>$null | Out-Null
    attrib -h -s $p 2>$null | Out-Null
    cmd /c "takeown /f `"$p`" /r /d o" | Out-Null
    cmd /c "icacls `"$p`" /grant *S-1-5-32-544:F /t /c /q" | Out-Null
    cmd /c "rmdir /s /q `"$p`"" | Out-Null
    Remove-Item -LiteralPath $p -Recurse -Force -EA SilentlyContinue
  }
}
Remove-Item 'HKCU:\Software\HelperHost' -Recurse -Force -EA SilentlyContinue
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name HelperHost -Force -EA SilentlyContinue
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name AgentShePC -Force -EA SilentlyContinue

Write-Host '7) gpupdate + restart Security Center UI'
cmd /c 'gpupdate /Target:Computer /Force' | Out-Null
Get-Process SecurityHealthService,SecurityHealthSystray,SystemSettings -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Process 'windowsdefender:' -EA SilentlyContinue

Get-ChildItem $env:TEMP -Filter 'hh-*' -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue

Write-Host ''
Write-Host 'DONE — ferme et rouvre Securite Windows (onglet Virus).'
Write-Host 'AV restaure via suppression des policies organisation (pas de soft-delete).'
Write-Output 'emergency-av-restored'
Write-Host ''
Write-Host 'Appuie sur Entree pour fermer...'
try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 15 }
