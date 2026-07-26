# Remet Windows Defender / Securite Windows a l'etat normal (annule politiques "organisation").
# A lancer en Admin. Idempotent.
#Requires -RunAsAdministrator
$ErrorActionPreference = 'SilentlyContinue'

foreach ($polRoot in @(
  'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender',
  'HKLM:\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows Defender',
  'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center'
)) {
  if (Test-Path $polRoot) { Remove-Item $polRoot -Recurse -Force }
}

Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name EnableSmartScreen -Force
Remove-Item 'HKLM:\SOFTWARE\Policies\Microsoft\MicrosoftEdge\PhishingFilter' -Recurse -Force

$rtpLive = 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection'
if (Test-Path $rtpLive) {
  foreach ($n in @(
    'DisableRealtimeMonitoring','DisableBehaviorMonitoring','DisableOnAccessProtection',
    'DisableScanOnRealtimeEnable','DisableIOAVProtection','DisableScriptScanning'
  )) { Remove-ItemProperty $rtpLive -Name $n -Force }
}

Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name TamperProtection -Force
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name TamperProtectionSource -Force

foreach ($svc in @('WinDefend','WdNisSvc','Sense','SecurityHealthService','wscsvc')) {
  $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
  if (Test-Path $k) { Set-ItemProperty $k -Name Start -Value 2 -Type DWord -Force }
  sc.exe config $svc start= auto | Out-Null
  Set-Service $svc -StartupType Automatic
  Start-Service $svc
}
foreach ($svc in @('WdNisDrv','WdFilter','WdBoot')) {
  $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
  if (Test-Path $k) { Set-ItemProperty $k -Name Start -Value 1 -Type DWord -Force }
  sc.exe config $svc start= system | Out-Null
}

if (Get-Command Set-MpPreference -EA SilentlyContinue) {
  Set-MpPreference -UILockdown $false
  Set-MpPreference -DisableRealtimeMonitoring $false
  Set-MpPreference -DisableBehaviorMonitoring $false
  Set-MpPreference -DisableBlockAtFirstSeen $false
  Set-MpPreference -DisableIOAVProtection $false
  Set-MpPreference -DisableScriptScanning $false
  Set-MpPreference -DisableArchiveScanning $false
  Set-MpPreference -DisableEmailScanning $false
  Set-MpPreference -PUAProtection Enabled
  Set-MpPreference -MAPSReporting Advanced
  Set-MpPreference -SubmitSamplesConsent 1
  Set-MpPreference -EnableNetworkProtection Enabled
  Set-MpPreference -CloudBlockLevel Default
}

Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name SmartScreenEnabled -Value 'Warn' -Type String -Force
gpupdate.exe /Target:Computer /Force | Out-Null
Write-Output 'defender-restored'
