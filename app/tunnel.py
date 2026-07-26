from __future__ import annotations

import logging
import os
import re
import signal
import subprocess
import threading
import time
from typing import Any

from app import config, store

log = logging.getLogger("agentshe.tunnel")

_URL_RE = re.compile(r"https://[a-zA-Z0-9.-]+\.trycloudflare\.com")
_proc: subprocess.Popen | None = None
_lock = threading.Lock()
_mode: str = "none"  # none | quick | named | external


def _is_loopback(url: str) -> bool:
    u = (url or "").lower()
    return (
        "127.0.0.1" in u
        or "localhost" in u
        or u.startswith("http://0.0.0.0")
        or "://[::1]" in u
    )


def is_stable_base() -> bool:
    """True when Connecter links are permanent (no rotating trycloudflare URL)."""
    return not _is_loopback(config.BASE_URL)


def tunnel_status() -> dict[str, Any]:
    with store.locked_state() as state:
        t = dict(state.get("tunnel") or {})
    pid = t.get("pid")
    alive = False
    if _proc is not None and _proc.poll() is None:
        alive = True
    elif pid:
        try:
            os.kill(int(pid), 0)
            alive = True
        except OSError:
            alive = False
    t["alive"] = alive
    t["mode"] = _mode or t.get("mode") or "none"
    t["stable"] = is_stable_base()
    return t


def ensure_public_base_url(timeout: float = 45.0) -> str:
    """
    Return the public base URL used in Connecter one-liners.

    Priority:
    1. Non-loopback BASE_URL (permanent) — optionally keep named tunnel alive
    2. Else Cloudflare quick tunnel (URL changes each restart — temporary)
    """
    global _mode
    configured = config.BASE_URL.rstrip("/")

    if not _is_loopback(configured):
        _mode = "named" if config.TUNNEL_TOKEN else "external"
        if config.TUNNEL_TOKEN:
            _ensure_named_tunnel()
        with store.locked_state() as state:
            state["tunnel"] = {
                "url": configured,
                "pid": _proc.pid if _proc else None,
                "started_at": time.time(),
                "port": config.PORT,
                "mode": _mode,
                "stable": True,
            }
        return configured

    # Ephemeral quick tunnel (URL rotates)
    with _lock:
        with store.locked_state() as state:
            t = state.setdefault("tunnel", {})
            existing = (t.get("url") or "").rstrip("/")
            pid = t.get("pid")
            if existing and t.get("mode") == "named":
                existing = ""
        if existing and _proc is not None and _proc.poll() is None:
            _mode = "quick"
            return existing
        if existing and pid:
            try:
                os.kill(int(pid), 0)
                if _proc is None:
                    _mode = "quick"
                    return existing
            except OSError:
                pass

        url = _start_cloudflared_quick(config.PORT, timeout=timeout)
        _mode = "quick"
        with store.locked_state() as state:
            state["tunnel"] = {
                "url": url,
                "pid": _proc.pid if _proc else None,
                "started_at": time.time(),
                "port": config.PORT,
                "mode": "quick",
                "stable": False,
            }
        log.warning(
            "Quick tunnel (éphémère): %s — pour un lien Connecter permanent, "
            "mets BASE_URL=https://ton-domaine et optionnellement TUNNEL_TOKEN=",
            url,
        )
        return url


def _ensure_named_tunnel() -> None:
    """Keep cloudflared running with a Zero Trust tunnel token (fixed hostname)."""
    global _proc, _mode
    with _lock:
        if _proc is not None and _proc.poll() is None:
            return
        bin_path = _cloudflared_bin()
        cmd = [bin_path, "tunnel", "--no-autoupdate", "run", "--token", config.TUNNEL_TOKEN]
        log.info("Starting named Cloudflare tunnel (fixed hostname → :%s)", config.PORT)
        _proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
        _mode = "named"

        def reader() -> None:
            assert _proc and _proc.stdout
            for line in _proc.stdout:
                line = (line or "").strip()
                if line:
                    log.debug("cloudflared: %s", line)

        threading.Thread(target=reader, daemon=True).start()


def stop_tunnel(*, force: bool = False) -> None:
    """
    Kill tunnel process.
    Named/external (stable BASE_URL) are kept unless force=True —
    Connecter links must keep working.
    """
    global _proc, _mode
    if is_stable_base() and not force:
        log.info("Skip stop_tunnel — BASE_URL permanent")
        return
    with _lock:
        proc = _proc
        _proc = None
        pid = None
        with store.locked_state() as state:
            t = state.get("tunnel") or {}
            pid = t.get("pid")
            state["tunnel"] = {}
        for p in filter(None, [proc.pid if proc else None, pid]):
            try:
                os.kill(int(p), signal.SIGTERM)
            except OSError:
                pass
        if proc and proc.poll() is None:
            try:
                proc.terminate()
                proc.wait(timeout=3)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
        try:
            subprocess.run(
                ["pkill", "-f", f"cloudflared tunnel --url http://127.0.0.1:{config.PORT}"],
                check=False,
                capture_output=True,
            )
        except Exception:
            pass
        _mode = "none"
        log.info("Tunnel stopped / wiped")


def maybe_stop_tunnel_if_idle() -> bool:
    """Stop ephemeral hosting when no sessions. Never stops a permanent BASE_URL setup."""
    if is_stable_base():
        return False
    sessions = store.list_sessions()
    if sessions:
        return False
    stop_tunnel()
    return True


def _start_cloudflared_quick(port: int, timeout: float = 45.0) -> str:
    global _proc
    bin_path = _cloudflared_bin()
    if _proc and _proc.poll() is None:
        try:
            _proc.terminate()
            _proc.wait(timeout=2)
        except Exception:
            pass
        _proc = None

    cmd = [
        bin_path,
        "tunnel",
        "--url",
        f"http://127.0.0.1:{port}",
        "--no-autoupdate",
    ]
    log.info("Starting quick tunnel: %s", " ".join(cmd))
    _proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        start_new_session=True,
    )
    url_holder: dict[str, str] = {}

    def reader() -> None:
        assert _proc and _proc.stdout
        for line in _proc.stdout:
            line = line.strip()
            if not line:
                continue
            log.debug("cloudflared: %s", line)
            m = _URL_RE.search(line)
            if m and "url" not in url_holder:
                url_holder["url"] = m.group(0).rstrip("/")

    th = threading.Thread(target=reader, daemon=True)
    th.start()
    deadline = time.time() + timeout
    while time.time() < deadline:
        if url_holder.get("url"):
            return url_holder["url"]
        if _proc.poll() is not None:
            raise RuntimeError("cloudflared s’est arrêté avant d’exposer l’URL")
        time.sleep(0.2)
    stop_tunnel(force=True)
    raise RuntimeError("Timeout: tunnel Cloudflare non prêt")


def _cloudflared_bin() -> str:
    for cand in ("cloudflared", "/usr/local/bin/cloudflared", "/usr/bin/cloudflared"):
        if cand == "cloudflared":
            from shutil import which

            w = which("cloudflared")
            if w:
                return w
        elif os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    raise RuntimeError(
        "cloudflared introuvable. Installe-le, ou sers le bot derrière une URL fixe (VPS)."
    )
