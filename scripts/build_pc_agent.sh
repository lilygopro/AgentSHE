#!/usr/bin/env bash
# Cross-compile HelperHost static binaries — no Python, no CGO.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
mkdir -p "$DIST"
export PATH="${HOME}/.local/go/bin:${PATH}"
cd "$ROOT/pc_agent"

build() {
  local goos="$1" goarch="$2" out="$3"
  echo "→ $out"
  CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" go build -trimpath -ldflags="-s -w" -o "$DIST/$out" .
}

build linux amd64 HelperHost-linux-amd64
build linux arm64 HelperHost-linux-arm64
build darwin amd64 HelperHost-darwin-amd64
build darwin arm64 HelperHost-darwin-arm64
build windows amd64 HelperHost-windows-amd64.exe

ls -lh "$DIST"
echo OK
