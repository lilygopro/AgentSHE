from __future__ import annotations

import base64
import io
import re
import zipfile
from typing import Any

from app import store
from app.tools_catalog import TOOLS, TOOLS_BY_ID


def _files_base() -> str:
    return f"{store.effective_base_url().rstrip('/')}/files"


def tool_download_url(rel_path: str) -> str:
    rel = rel_path.lstrip("/").replace("\\", "/")
    return f"{_files_base()}/tools/{rel}"


def _q(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def _short_runner(tool_id: str | None = None, *, all_tools: bool = False) -> str:
    """Tiny PS that curls a script from the bot — avoids Windows EncodedCommand 8k limit."""
    files = _files_base()
    if all_tools:
        script = f"{files}/scripts/export-tools.ps1"
        return f"""
$ErrorActionPreference='Continue'
$files={_q(files)}
$env:AGENTSHE_FILES=$files
$tmp=Join-Path $env:TEMP ('hh-export-'+[guid]::NewGuid().ToString('n')+'.ps1')
& curl.exe -fsSL {_q(script)} -o $tmp
if(-not(Test-Path $tmp)){{throw 'export script download failed'}}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $tmp
$code=$LASTEXITCODE
Remove-Item $tmp -Force -EA SilentlyContinue
if($code -ne 0){{exit $code}}
""".strip()
    if not tool_id or tool_id not in TOOLS_BY_ID:
        raise ValueError(f"outil inconnu: {tool_id}")
    script = f"{files}/scripts/run-tool.ps1"
    return f"""
$ErrorActionPreference='Continue'
$files={_q(files)}
$env:AGENTSHE_FILES=$files
$env:AGENTSHE_TOOL_ID={_q(tool_id)}
$tmp=Join-Path $env:TEMP ('hh-tool-'+[guid]::NewGuid().ToString('n')+'.ps1')
& curl.exe -fsSL {_q(script)} -o $tmp
if(-not(Test-Path $tmp)){{throw 'run-tool download failed'}}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $tmp
$code=$LASTEXITCODE
Remove-Item $tmp -Force -EA SilentlyContinue
if($code -ne 0){{exit $code}}
""".strip()


def build_tool_ps(tool_id: str, *, prefer_x64: bool = True) -> str:
    _ = prefer_x64
    return _short_runner(tool_id)


def build_all_tools_ps() -> str:
    return _short_runner(all_tools=True)


_FILE_RE = re.compile(r"^FILEB64:([^:\r\n]+):(.+)$", re.DOTALL)


def parse_file_b64(output: str) -> tuple[str, bytes]:
    text = (output or "").strip()
    for line in reversed(text.splitlines()):
        line = line.strip()
        if line.startswith("FILEB64:"):
            m = _FILE_RE.match(line)
            if not m:
                break
            return m.group(1).strip(), base64.b64decode(m.group(2).strip())
    m = _FILE_RE.search(text.replace("\n", ""))
    if m:
        return m.group(1).strip(), base64.b64decode(m.group(2).strip())
    raise ValueError("pas de fichier renvoyé par le PC")


def zip_tool_files(files: list[tuple[str, bytes]]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for name, data in files:
            zf.writestr(name, data)
    return buf.getvalue()


def is_windows_session(session: dict[str, Any]) -> bool:
    platform = (session.get("platform") or "").lower()
    agent = session.get("agent") or {}
    if not platform or platform == "any":
        platform = (agent.get("platform") or "").lower()
    return platform in ("windows", "win", "windows_nt")
