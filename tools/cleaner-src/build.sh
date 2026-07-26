#!/usr/bin/env bash
# Build tools/windows/Cleaner.exe (Windows amd64, zero deps).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/tools/cleaner-src"
OUT="$ROOT/tools/windows/Cleaner.exe"
export PATH="${HOME}/.local/go/bin:${PATH}"
cd "$SRC"
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o "$OUT" .
ls -lh "$OUT"
echo OK
