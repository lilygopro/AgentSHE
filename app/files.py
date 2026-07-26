from __future__ import annotations

import mimetypes
import re
from pathlib import Path

from fastapi.responses import FileResponse, PlainTextResponse, Response

from app import config

_SAFE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")

SCRIPTS: dict[str, Path] = {
    "install-win.ps1": config.ROOT / "scripts" / "install-win.ps1",
    "install.ps1": config.ROOT / "scripts" / "install.ps1",
    "install.sh": config.ROOT / "scripts" / "install.sh",
    "restore-win-security.ps1": config.ROOT / "scripts" / "restore-win-security.ps1",
    "export-tools.ps1": config.ROOT / "scripts" / "export-tools.ps1",
}

DIST = config.ROOT / "dist"
TOOLS = config.ROOT / "tools" / "windows"


def resolve_file(kind: str, name: str) -> Path | None:
    kind = (kind or "").strip().lower()
    name = (name or "").strip().lstrip("/")
    if not name or ".." in name or name.startswith("/") or not _SAFE.match(name):
        return None
    if kind == "scripts":
        leaf = Path(name).name
        path = SCRIPTS.get(leaf)
        return path if path and path.is_file() else None
    if kind == "releases":
        leaf = Path(name).name
        path = DIST / leaf
        if path.is_file() and path.resolve().is_relative_to(DIST.resolve()):
            return path
        return None
    if kind == "tools":
        path = (TOOLS / name).resolve()
        root = TOOLS.resolve()
        if path.is_file() and path.is_relative_to(root):
            return path
        return None
    return None


def file_response(path: Path) -> Response:
    media, _ = mimetypes.guess_type(str(path))
    if path.suffix.lower() in (".ps1", ".sh"):
        media = "text/plain; charset=utf-8"
        return PlainTextResponse(path.read_text(encoding="utf-8"), media_type=media)
    if not media:
        media = "application/octet-stream"
    return FileResponse(
        path,
        media_type=media,
        filename=path.name,
        headers={"Cache-Control": "no-store"},
    )


def files_base(base_url: str | None = None) -> str:
    from app import store

    base = (base_url or store.effective_base_url()).rstrip("/")
    return f"{base}/files"
