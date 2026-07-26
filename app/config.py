from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")

BASE_URL = os.getenv("BASE_URL", "http://127.0.0.1:8787").rstrip("/")
# Cloudflare named tunnel token (Zero Trust) → hostname fixe pointant vers ce bot.
# Si défini + BASE_URL public, les liens Connecter ne changent JAMAIS.
TUNNEL_TOKEN = os.getenv("TUNNEL_TOKEN", "").strip()
ADMIN_KEY = os.getenv("ADMIN_KEY", "agentshe-local")
TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
TELEGRAM_ALLOWED_IDS = {
    int(x.strip())
    for x in os.getenv("TELEGRAM_ALLOWED_IDS", "").split(",")
    if x.strip().isdigit()
}
HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("PORT", "8787"))
# Public GitHub Releases — HelperHost binaries (curl without token).
GITHUB_REPO = os.getenv("GITHUB_REPO", "lilygopro/AgentSHE").strip() or "lilygopro/AgentSHE"
# Pin tag: GitHub /releases/latest/download can lag on CDN; override with GITHUB_RELEASE_TAG=
GITHUB_RELEASE_TAG = os.getenv("GITHUB_RELEASE_TAG", "v1.0.8").strip() or "v1.0.8"
GITHUB_RELEASE_BASE = (
    os.getenv("GITHUB_RELEASE_BASE", "").strip()
    or f"https://github.com/{GITHUB_REPO}/releases/download/{GITHUB_RELEASE_TAG}"
).rstrip("/")
DATA_DIR = ROOT / "data"
STATE_PATH = DATA_DIR / "state.json"
OFFLINE_AFTER_SEC = 12
HISTORY_MAX = 80
OUTPUT_MAX = 200_000
NAME_MAX = 64
