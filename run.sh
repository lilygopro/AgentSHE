#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -d .venv ]; then
  python3 -m venv .venv
  .venv/bin/pip install -r requirements.txt
fi
# PC agent = static HelperHost binaries (no Python on target PCs)
if [ ! -f dist/HelperHost-linux-amd64 ]; then
  echo "Build HelperHost (binaire Go, 0 dépendance PC)…"
  export PATH="${HOME}/.local/go/bin:${PATH}"
  ./scripts/build_pc_agent.sh
fi
# shellcheck disable=SC1091
set -a
[ -f .env ] && . ./.env
set +a
exec .venv/bin/uvicorn app.main:app --host "${HOST:-0.0.0.0}" --port "${PORT:-8787}" --reload
