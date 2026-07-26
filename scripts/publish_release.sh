#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${HOME}/.local/bin:${HOME}/.local/go/bin:${PATH}"
REPO="${GITHUB_REPO:-lilygopro/AgentSHE}"
DIST="$ROOT/dist"

cd "$ROOT"

if ! command -v gh >/dev/null; then
  echo "gh CLI manquant (export PATH=\$HOME/.local/bin:\$PATH)" >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "gh non connecté — lance: gh auth login" >&2
  exit 1
fi

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  latest="$(gh release list -R "$REPO" --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || true)"
  if [[ "$latest" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    VERSION="v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
  else
    VERSION="v1.0.0"
  fi
fi
[[ "$VERSION" == v* ]] || VERSION="v$VERSION"

echo "==> Build HelperHost ($VERSION)"
bash "$ROOT/scripts/build_pc_agent.sh"

assets=(
  HelperHost-linux-amd64
  HelperHost-linux-arm64
  HelperHost-darwin-amd64
  HelperHost-darwin-arm64
  HelperHost-windows-amd64.exe
)
for a in "${assets[@]}"; do
  [ -f "$DIST/$a" ] || { echo "manque $DIST/$a" >&2; exit 1; }
done

cp -f "$ROOT/scripts/install.sh" "$DIST/install.sh"
cp -f "$ROOT/scripts/install.ps1" "$DIST/install.ps1"
assets+=(install.sh install.ps1)

echo "==> Commit + push (si git remote ok)"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "release $VERSION"
  fi
  git push -u origin HEAD 2>/dev/null || git push 2>/dev/null || true
fi

echo "==> GitHub Release $REPO $VERSION"
upload_args=()
for a in "${assets[@]}"; do
  upload_args+=("$DIST/$a")
done
if gh release view "$VERSION" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "$VERSION" -R "$REPO" --clobber "${upload_args[@]}"
else
  gh release create "$VERSION" -R "$REPO" \
    --title "$VERSION" \
    --notes "" \
    "${upload_args[@]}"
fi

echo
echo "OK — latest download:"
echo "  https://github.com/${REPO}/releases/latest/download/HelperHost-darwin-arm64"
echo "  https://github.com/${REPO}/releases/latest/download/HelperHost-windows-amd64.exe"
