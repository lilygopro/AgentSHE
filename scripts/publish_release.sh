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
cp -f "$ROOT/scripts/install-win.ps1" "$ROOT/scripts/install.ps1"
cp -f "$ROOT/scripts/install.ps1" "$DIST/install.ps1"
cp -f "$ROOT/scripts/restore-win-security.ps1" "$ROOT/pc_agent/embed/restore-win-security.ps1" 2>/dev/null || true
assets+=(install.sh install.ps1)

echo "==> Commit + push (repo privé — auth gh requise)"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add \
    pc_agent \
    scripts/build_pc_agent.sh \
    scripts/publish_release.sh \
    scripts/install.sh \
    scripts/install.ps1 \
    scripts/install-win.ps1 \
    scripts/restore-win-security.ps1 \
    scripts/emergency-av-restore.ps1 \
    scripts/export-tools.ps1 \
    tools \
    app/files.py \
    app/main.py \
    app/pc_tools.py \
    app/tools_catalog.py \
    .gitignore \
    2>/dev/null || true
  if ! git diff --cached --quiet 2>/dev/null; then
    git -c user.name="${GIT_AUTHOR_NAME:-lilygopro}" \
        -c user.email="${GIT_AUTHOR_EMAIL:-lilygopro@users.noreply.github.com}" \
        commit -m "release $VERSION"
  fi
  git push -u origin HEAD
fi

echo "==> GitHub Release $REPO $VERSION (privé — downloads via bot /files, pas raw public)"
upload_args=()
for a in "${assets[@]}"; do
  upload_args+=("$DIST/$a")
done
if gh release view "$VERSION" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "$VERSION" -R "$REPO" --clobber "${upload_args[@]}"
else
  gh release create "$VERSION" -R "$REPO" \
    --title "$VERSION" \
    --notes "Private release. PCs download via bot tunnel /files/releases/" \
    "${upload_args[@]}"
fi

# Keep .env tag in sync if present
if [ -f "$ROOT/.env" ]; then
  if grep -q '^GITHUB_RELEASE_TAG=' "$ROOT/.env"; then
    sed -i "s/^GITHUB_RELEASE_TAG=.*/GITHUB_RELEASE_TAG=$VERSION/" "$ROOT/.env"
  else
    echo "GITHUB_RELEASE_TAG=$VERSION" >> "$ROOT/.env"
  fi
fi

echo
echo "OK — $VERSION"
echo "  Local (bot sert ça): $DIST/"
echo "  Remote privé: gh release view $VERSION -R $REPO"
echo "  PC downloads: <tunnel>/files/releases/HelperHost-windows-amd64.exe"
