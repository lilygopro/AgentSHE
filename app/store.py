from __future__ import annotations

import json
import os
import threading
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from hashlib import sha256
from typing import Any

from app import config

_lock = threading.RLock()


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _now_ts() -> float:
    return time.time()


def default_state() -> dict[str, Any]:
    return {"sessions": {}, "telegram": {}, "enrolls": {}, "tunnel": {}, "bot_owner_id": None}


def ensure_data_dir() -> None:
    config.DATA_DIR.mkdir(parents=True, exist_ok=True)


@contextmanager
def locked_state():
    ensure_data_dir()
    with _lock:
        state = _load_unlocked()
        yield state
        _save_unlocked(state)


def _load_unlocked() -> dict[str, Any]:
    path = config.STATE_PATH
    if not path.is_file():
        return default_state()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return default_state()
    if not isinstance(data, dict):
        return default_state()
    data.setdefault("sessions", {})
    data.setdefault("telegram", {})
    data.setdefault("enrolls", {})
    data.setdefault("tunnel", {})
    data.setdefault("bot_owner_id", None)
    return data


def _save_unlocked(state: dict[str, Any]) -> None:
    ensure_data_dir()
    path = config.STATE_PATH
    tmp = path.with_suffix(f".tmp.{os.getpid()}")
    raw = json.dumps(state, ensure_ascii=False, separators=(",", ":"))
    tmp.write_text(raw, encoding="utf-8")
    os.replace(tmp, path)


def get_bot_owner_id() -> int | None:
    with locked_state() as state:
        oid = state.get("bot_owner_id")
        if oid is not None:
            try:
                return int(oid)
            except (TypeError, ValueError):
                return None
    return None


def set_bot_owner_id(user_id: int) -> None:
    with locked_state() as state:
        if state.get("bot_owner_id") is None:
            state["bot_owner_id"] = int(user_id)


def is_telegram_allowed(user_id: int) -> bool:
    """Only the owner can use the bot. Env allowlist wins if set."""
    if config.TELEGRAM_ALLOWED_IDS:
        return user_id in config.TELEGRAM_ALLOWED_IDS
    owner = get_bot_owner_id()
    if owner is None:
        set_bot_owner_id(user_id)
        return True
    return user_id == owner


def hash_token(token: str) -> str:
    return sha256(token.encode("utf-8")).hexdigest()


def new_token() -> str:
    return uuid.uuid4().hex + uuid.uuid4().hex[:16]


def new_session_id() -> str:
    return uuid.uuid4().hex[:12]


def is_online(session: dict[str, Any]) -> bool:
    """Online = PC a un callback et a répondu récemment (pas d’expiry de session)."""
    if not session.get("callback_url"):
        return False
    last = session.get("last_ok_at")
    if last is None:
        return False
    try:
        # Affichage seulement — la session reste valide même hors ligne
        return (_now_ts() - float(last)) <= 90
    except (TypeError, ValueError):
        return False


def public_session(session: dict[str, Any], include_token: bool = False) -> dict[str, Any]:
    out = {
        "id": session["id"],
        "name": session["name"],
        "platform": session.get("platform", "any"),
        "created_at": session.get("created_at"),
        "online": is_online(session),
        "callback_url": session.get("callback_url"),
        "agent": session.get("agent"),
        "history": session.get("history") or [],
        "token_hint": session.get("token_hint"),
        "wipe_pending": bool(session.get("wipe_pending")),
        # Sessions are infinite until explicit delete
        "persistent": True,
    }
    if include_token and session.get("token"):
        out["token"] = session["token"]
    return out

def list_sessions(owner_telegram_id: int | None = None) -> list[dict[str, Any]]:
    with locked_state() as state:
        sessions = []
        for s in state["sessions"].values():
            if owner_telegram_id is not None:
                ow = s.get("owner_telegram_id")
                try:
                    if ow is None or int(ow) != int(owner_telegram_id):
                        continue
                except (TypeError, ValueError):
                    continue
            sessions.append(public_session(s))
    sessions.sort(key=lambda s: s.get("created_at") or "", reverse=True)
    return sessions


def get_session(session_id: str) -> dict[str, Any] | None:
    with locked_state() as state:
        s = state["sessions"].get(session_id)
        return public_session(s, include_token=True) if s else None


def get_session_raw(session_id: str) -> dict[str, Any] | None:
    with locked_state() as state:
        s = state["sessions"].get(session_id)
        return dict(s) if s else None


def delete_session(session_id: str) -> dict[str, Any] | None:
    """Purge session + command history + tokens from bot storage."""
    with locked_state() as state:
        s = state["sessions"].pop(session_id, None)
        if not s:
            return None
        if isinstance(s.get("history"), list):
            for h in s["history"]:
                if isinstance(h, dict):
                    h["command"] = ""
                    h["output"] = ""
            s["history"] = []
        owner = s.get("owner_telegram_id")
        name = s.get("name")
        s["token"] = None
        s["token_hash"] = None
        s["callback_url"] = None
        s["agent"] = None
        s["wipe_pending"] = False
        for _uid, meta in list(state.get("telegram", {}).items()):
            if meta.get("session_id") == session_id:
                meta["session_id"] = None
            meta.pop("pending_mac", None)
            meta.pop("pending_win", None)
        return {"id": session_id, "name": name, "owner_telegram_id": owner}


def mark_wipe_pending(session_id: str) -> dict[str, Any] | None:
    """Keep session until PC is online and confirms local wipe."""
    with locked_state() as state:
        s = state["sessions"].get(session_id)
        if not s:
            return None
        s["wipe_pending"] = True
        s["wipe_requested_at"] = _now()
        for _uid, meta in list(state.get("telegram", {}).items()):
            if meta.get("session_id") == session_id:
                meta["session_id"] = None
        return {
            "id": session_id,
            "name": s.get("name"),
            "owner_telegram_id": s.get("owner_telegram_id"),
        }


def list_wipe_pending() -> list[dict[str, Any]]:
    with locked_state() as state:
        out = []
        for s in state["sessions"].values():
            if s.get("wipe_pending"):
                out.append(public_session(s, include_token=True))
        return out


def expire_stale_wipes(max_age_sec: int = 90) -> list[dict[str, Any]]:
    """If wipe ack never arrives, force-purge so the bot doesn't hang forever."""
    now = _now_ts()
    done: list[dict[str, Any]] = []
    with locked_state() as state:
        for sid, s in list(state["sessions"].items()):
            if not s.get("wipe_pending"):
                continue
            req = s.get("wipe_requested_at") or s.get("created_at") or ""
            # wipe_requested_at is ISO from _now(); fall back to age via last_ok
            try:
                from datetime import datetime

                t0 = datetime.fromisoformat(str(req).replace("Z", "+00:00"))
                age = now - t0.timestamp()
            except Exception:
                age = max_age_sec + 1
            if age < max_age_sec:
                continue
            owner = s.get("owner_telegram_id")
            name = s.get("name")
            state["sessions"].pop(sid, None)
            for _uid, meta in list(state.get("telegram", {}).items()):
                if meta.get("session_id") == sid:
                    meta["session_id"] = None
            done.append({"id": sid, "name": name, "owner_telegram_id": owner})
    return done


def wipe_check_by_token(token: str) -> dict[str, Any]:
    """PC asks: should I self-destruct?"""
    token = (token or "").strip()
    if not token:
        return {"ok": False, "wipe": False}
    with locked_state() as state:
        for s in state["sessions"].values():
            if s.get("token") == token or s.get("token_hash") == hash_token(token):
                return {
                    "ok": True,
                    "wipe": bool(s.get("wipe_pending")),
                    "session_id": s["id"],
                    "name": s.get("name"),
                }
    return {"ok": False, "wipe": False}


def confirm_wiped_by_token(token: str) -> dict[str, Any] | None:
    """PC reports local wipe done → purge bot session."""
    token = (token or "").strip()
    if not token:
        return None
    sid = None
    with locked_state() as state:
        for s in state["sessions"].values():
            if s.get("token") == token or s.get("token_hash") == hash_token(token):
                sid = s["id"]
                break
    if not sid:
        return None
    return delete_session(sid)

def session_count() -> int:
    with locked_state() as state:
        return len(state.get("sessions") or {})


def telegram_get_binding(user_id: int) -> dict[str, Any]:
    with locked_state() as state:
        return dict(state.get("telegram", {}).get(str(user_id), {}))


def telegram_set_session(user_id: int, session_id: str | None) -> None:
    with locked_state() as state:
        tg = state.setdefault("telegram", {})
        meta = tg.setdefault(str(user_id), {})
        meta["session_id"] = session_id
        meta["updated_at"] = _now()


def telegram_set_ui_message(user_id: int, message_id: int | None) -> None:
    with locked_state() as state:
        tg = state.setdefault("telegram", {})
        meta = tg.setdefault(str(user_id), {})
        if message_id:
            meta["ui_message_id"] = int(message_id)
        else:
            meta.pop("ui_message_id", None)
        meta["updated_at"] = _now()


def ensure_enroll_key(user_id: int) -> str:
    with locked_state() as state:
        tg = state.setdefault("telegram", {})
        meta = tg.setdefault(str(user_id), {})
        key = meta.get("enroll_key")
        if not key:
            key = uuid.uuid4().hex
            meta["enroll_key"] = key
            meta["updated_at"] = _now()
        enrolls = state.setdefault("enrolls", {})
        enrolls[key] = {"telegram_id": user_id, "updated_at": _now()}
        return key


def effective_base_url() -> str:
    """Prefer permanent BASE_URL; only then ephemeral tunnel URL."""
    from app.tunnel import is_stable_base

    if is_stable_base():
        return config.BASE_URL.rstrip("/")
    with locked_state() as state:
        url = ((state.get("tunnel") or {}).get("url") or "").rstrip("/")
        if url:
            return url
    return config.BASE_URL.rstrip("/")


def connect_commands(user_id: int, base_url: str | None = None) -> dict[str, str]:
    """One-shot install: short command that works in PowerShell AND CMD."""
    key = ensure_enroll_key(user_id)
    base = (base_url or effective_base_url()).rstrip("/")
    files = f"{base}/files"
    rel = f"{files}/releases"
    raw_sh = f"{files}/scripts/install.sh"
    boot = f"{base}/connect/win.ps1?e={key}"

    # PowerShell-native (user often pastes in PS). Hidden via mshta style=0 — no taskbar.
    # Also works if launched as: powershell -c "..."
    win_cmd = (
        f"$p=Join-Path $env:TEMP 'hh.ps1'; "
        f"curl.exe -fsSL '{boot}' -o $p; "
        f"Start-Process -FilePath mshta -WindowStyle Hidden -ArgumentList "
        f"('vbscript:Execute(\"CreateObject(\"\"WScript.Shell\"\").Run \"\"powershell.exe "
        f"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"\"\"\"'+$p+'\"\"\"\"\"\",0:close\")'); "
        f"exit"
    )

    return {
        "enroll_key": key,
        "base_url": base,
        "files_base": files,
        "github_release": rel,
        "mac": (
            f"export AGENTSHE_GH='{rel}'; "
            f"curl -fsSL '{raw_sh}' | bash -s -- '{key}' '{base}'"
        ),
        "windows": win_cmd,
    }


def resolve_enroll_owner(enroll_key: str) -> int | None:
    with locked_state() as state:
        info = (state.get("enrolls") or {}).get(enroll_key)
        if info:
            return int(info["telegram_id"])
        for uid, meta in (state.get("telegram") or {}).items():
            if meta.get("enroll_key") == enroll_key:
                return int(uid)
    return None


def enroll_pc(
    enroll_key: str,
    hostname: str,
    callback_url: str,
    platform: str = "any",
    user: str = "",
    os_name: str = "",
) -> dict[str, Any]:
    """
    Register a self-hosted PC session.
    Session persists until explicit delete.
    """
    hostname = (hostname or "").strip()[: config.NAME_MAX] or "unknown-pc"
    callback_url = (callback_url or "").rstrip("/")
    if not callback_url.startswith("https://") and not callback_url.startswith("http://"):
        return {"ok": False, "error": "callback_url invalide", "code": 400}

    owner = resolve_enroll_owner(enroll_key)
    if owner is None:
        return {"ok": False, "error": "enroll invalide", "code": 401}

    platform = platform if platform in ("mac", "windows", "linux", "unix", "any") else "any"
    if platform == "unix":
        platform = "linux"

    with locked_state() as state:
        existing = None
        for s in state["sessions"].values():
            if s.get("owner_telegram_id") == owner and s.get("name") == hostname:
                existing = s
                break

        # Pending wipe: refresh callback so bot can push /shutdown, tell PC to self-erase.
        if existing and existing.get("wipe_pending"):
            existing["callback_url"] = callback_url
            existing["last_ok_at"] = _now_ts()
            existing["agent"] = {
                "hostname": hostname,
                "user": user[:128],
                "os": os_name[:128],
                "platform": platform,
            }
            return {
                "ok": True,
                "wipe": True,
                "token": existing["token"],
                "session_id": existing["id"],
                "name": existing["name"],
                "telegram_id": owner,
            }

        token = new_token()
        fresh = False
        if existing:
            existing["token"] = token
            existing["token_hash"] = hash_token(token)
            existing["token_hint"] = token[:6] + "…" + token[-4:]
            existing["callback_url"] = callback_url
            existing["platform"] = platform
            existing["wipe_pending"] = False
            existing["agent"] = {
                "hostname": hostname,
                "user": user[:128],
                "os": os_name[:128],
                "platform": platform,
            }
            existing["last_ok_at"] = _now_ts()
            # keep created_at — session is the same infinite session
            session = existing
        else:
            sid = new_session_id()
            session = {
                "id": sid,
                "name": hostname,
                "platform": platform,
                "owner_telegram_id": owner,
                "token": token,
                "token_hash": hash_token(token),
                "token_hint": token[:6] + "…" + token[-4:],
                "callback_url": callback_url,
                "created_at": _now(),
                "agent": {
                    "hostname": hostname,
                    "user": user[:128],
                    "os": os_name[:128],
                    "platform": platform,
                },
                "last_ok_at": _now_ts(),
                "history": [],
            }
            state["sessions"][sid] = session
            fresh = True

        tg = state.setdefault("telegram", {})
        meta = tg.setdefault(str(owner), {})
        meta["session_id"] = session["id"]
        meta["enroll_key"] = enroll_key
        meta["updated_at"] = _now()

        return {
            "ok": True,
            "wipe": False,
            "fresh": fresh,
            "token": token,
            "session_id": session["id"],
            "name": session["name"],
            "telegram_id": owner,
        }


def touch_session(session_id: str) -> None:
    with locked_state() as state:
        s = state["sessions"].get(session_id)
        if s:
            s["last_ok_at"] = _now_ts()


def append_history(session_id: str, command: str, output: str, exit_code: int) -> None:
    with locked_state() as state:
        s = state["sessions"].get(session_id)
        if not s:
            return
        hist = s.setdefault("history", [])
        hist.append(
            {
                "id": uuid.uuid4().hex[:12],
                "command": command,
                "output": (output or "")[: config.OUTPUT_MAX],
                "exit_code": exit_code,
                "at": _now(),
                "done": True,
            }
        )
        s["history"] = hist[-config.HISTORY_MAX :]
        s["last_ok_at"] = _now_ts()


def verify_session_token(session_id: str, token: str) -> bool:
    with locked_state() as state:
        s = state["sessions"].get(session_id)
        if not s:
            return False
        return s.get("token") == token or s.get("token_hash") == hash_token(token)
