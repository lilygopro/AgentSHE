from __future__ import annotations

import asyncio
import logging
from typing import Any

import httpx

from app import config, remote, store
from app import pc_tools
from app.tools_catalog import TOOLS, TOOLS_BY_ID

logging.basicConfig(level=logging.INFO)
logging.getLogger("httpx").setLevel(logging.WARNING)
log = logging.getLogger("agentshe.telegram")
API = "https://api.telegram.org/bot{token}"

MAIN_KEYBOARD = None  # legacy unused
REMOVE_KEYBOARD = {"remove_keyboard": True}

NAV_HOME = {
    "inline_keyboard": [
        [
            {"text": "🖥 Machines", "callback_data": "menu:machines"},
            {"text": "🔗 Connecter", "callback_data": "menu:connect"},
        ],
        [{"text": "« Menu", "callback_data": "menu:home"}],
    ]
}

# Alias for older call sites
NAV_INLINE = NAV_HOME


def _machine_keyboard(sid: str | None = None) -> dict[str, Any]:
    """Actions scoped to the currently selected machine only."""
    return {
        "inline_keyboard": [
            [
                {"text": "⌨️ Terminal", "callback_data": "menu:terminal"},
                {"text": "🧰 Outils", "callback_data": "menu:tools"},
            ],
            [
                {"text": "📡 Status", "callback_data": "menu:status"},
                {
                    "text": "🗑 Supprimer",
                    "callback_data": f"delask:{sid}" if sid else "menu:delete",
                },
            ],
            [
                {"text": "🖥 Autres machines", "callback_data": "menu:machines"},
                {"text": "« Menu", "callback_data": "menu:home"},
            ],
        ]
    }


def _allowed(user_id: int) -> bool:
    return store.is_telegram_allowed(user_id)


async def _api(client: httpx.AsyncClient, method: str, **params: Any) -> dict[str, Any]:
    url = API.format(token=config.TELEGRAM_BOT_TOKEN) + "/" + method
    r = await client.post(url, json=params, timeout=60)
    data = r.json()
    if not data.get("ok"):
        desc = str(data.get("description") or "")
        if "message is not modified" not in desc.lower():
            log.warning("Telegram API %s: %s", method, data)
    return data


async def _send(
    client: httpx.AsyncClient,
    chat_id: int,
    text: str,
    *,
    reply_markup: dict[str, Any] | None = None,
) -> int | None:
    chunk = text if len(text) <= 4000 else text[:3990] + "\n…"
    params: dict[str, Any] = {"chat_id": chat_id, "text": chunk}
    if reply_markup is not None:
        params["reply_markup"] = reply_markup
    data = await _api(client, "sendMessage", **params)
    if data.get("ok"):
        return int((data.get("result") or {}).get("message_id") or 0) or None
    return None


async def _send_document(
    client: httpx.AsyncClient,
    chat_id: int,
    data: bytes,
    filename: str,
    caption: str = "",
) -> bool:
    url = API.format(token=config.TELEGRAM_BOT_TOKEN) + "/sendDocument"
    files = {"document": (filename, data)}
    form = {"chat_id": str(chat_id)}
    if caption:
        form["caption"] = caption[:1024]
    r = await client.post(url, data=form, files=files, timeout=120)
    try:
        body = r.json()
    except Exception:
        body = {}
    if not body.get("ok"):
        log.warning("sendDocument: %s", body)
        return False
    return True


async def _edit(
    client: httpx.AsyncClient,
    chat_id: int,
    message_id: int,
    text: str,
    reply_markup: dict[str, Any] | None = None,
) -> bool:
    chunk = text if len(text) <= 4000 else text[:3990] + "\n…"
    params: dict[str, Any] = {
        "chat_id": chat_id,
        "message_id": message_id,
        "text": chunk,
    }
    if reply_markup is not None:
        params["reply_markup"] = reply_markup
    data = await _api(client, "editMessageText", **params)
    if data.get("ok"):
        return True
    desc = str(data.get("description") or "").lower()
    return "message is not modified" in desc


async def _answer_cb(
    client: httpx.AsyncClient, callback_id: str, text: str = "", show_alert: bool = False
) -> None:
    await _api(
        client,
        "answerCallbackQuery",
        callback_query_id=callback_id,
        text=text[:200],
        show_alert=show_alert,
    )


async def _panel(
    client: httpx.AsyncClient,
    chat_id: int,
    user_id: int,
    text: str,
    reply_markup: dict[str, Any] | None = None,
    *,
    message_id: int | None = None,
    force_new: bool = False,
) -> int | None:
    """Update the UI panel in place, or send a fresh one."""
    if force_new:
        store.telegram_set_ui_message(user_id, None)
        mid_i = 0
    else:
        mid = message_id or store.telegram_get_binding(user_id).get("ui_message_id")
        try:
            mid_i = int(mid) if mid else 0
        except (TypeError, ValueError):
            mid_i = 0
        if mid_i:
            data = await _api(
                client,
                "editMessageText",
                chat_id=chat_id,
                message_id=mid_i,
                text=text if len(text) <= 4000 else text[:3990] + "\n…",
                **({"reply_markup": reply_markup} if reply_markup is not None else {}),
            )
            if data.get("ok"):
                store.telegram_set_ui_message(user_id, mid_i)
                return mid_i
            desc = str(data.get("description") or "").lower()
            if "message is not modified" in desc:
                store.telegram_set_ui_message(user_id, mid_i)
                return mid_i
            # stale / not editable → fall through to new message
            store.telegram_set_ui_message(user_id, None)

    new_id = await _send(client, chat_id, text, reply_markup=reply_markup)
    if new_id:
        store.telegram_set_ui_message(user_id, new_id)
    return new_id


def _active_name(user_id: int) -> str | None:
    binding = store.telegram_get_binding(user_id)
    sid = binding.get("session_id")
    if not sid:
        return None
    s = store.get_session(sid)
    return s["name"] if s else None


async def ui_home(
    client: httpx.AsyncClient,
    chat_id: int,
    user_id: int,
    *,
    message_id: int | None = None,
    force_new: bool = False,
) -> None:
    sessions = store.list_sessions(owner_telegram_id=user_id)
    active = _active_name(user_id)
    lines = [
        "AgentShe",
        "",
        "1) Connecter un PC",
        "2) Choisir une machine",
        "3) Terminal / Outils sur CETTE machine",
        "",
    ]
    if active:
        lines.append(f"Machine ouverte: « {active} »")
    else:
        lines.append("Aucune machine ouverte.")
    lines.append(f"Machines: {len(sessions)}")
    await _panel(
        client,
        chat_id,
        user_id,
        "\n".join(lines),
        NAV_HOME,
        message_id=message_id,
        force_new=force_new,
    )


async def ui_connect(
    client: httpx.AsyncClient,
    chat_id: int,
    user_id: int,
    *,
    message_id: int | None = None,
) -> None:
    await _panel(
        client,
        chat_id,
        user_id,
        "Préparation du lien…",
        {"inline_keyboard": [[{"text": "…", "callback_data": "menu:home"}]]},
        message_id=message_id,
    )
    mid = store.telegram_get_binding(user_id).get("ui_message_id")
    try:
        from app import tunnel

        public = await asyncio.to_thread(tunnel.ensure_public_base_url)
        stable = tunnel.is_stable_base()
    except Exception as e:
        await _panel(
            client,
            chat_id,
            user_id,
            f"Échec: {e}",
            NAV_INLINE,
            message_id=mid,
        )
        return
    cmds = store.connect_commands(user_id, base_url=public)
    with store.locked_state() as state:
        meta = state.setdefault("telegram", {}).setdefault(str(user_id), {})
        meta["pending_mac"] = cmds["mac"]
        meta["pending_win"] = cmds["windows"]

    if stable:
        note = (
            "✅ Lien PERMANENT\n"
            f"Bot: {public}\n"
            "HelperHost: GitHub\n\n"
            "1× par nouveau PC."
        )
    else:
        note = (
            "⚠️ URL bot temporaire\n"
            "HelperHost: GitHub (fixe)\n\n"
            "1× par nouveau PC."
        )
    await _panel(
        client,
        chat_id,
        user_id,
        note + "\n\nChoisis l’OS:",
        {
            "inline_keyboard": [
                [
                    {"text": "Mac / Linux", "callback_data": "conn:mac"},
                    {"text": "Windows", "callback_data": "conn:win"},
                ],
                [{"text": "« Menu", "callback_data": "menu:home"}],
            ]
        },
        message_id=mid,
    )


async def ui_show_install_cmd(
    client: httpx.AsyncClient,
    chat_id: int,
    user_id: int,
    kind: str,
    *,
    message_id: int | None = None,
) -> None:
    binding = store.telegram_get_binding(user_id)
    cmd = binding.get("pending_mac" if kind == "mac" else "pending_win") or ""
    if not cmd:
        await ui_connect(client, chat_id, user_id, message_id=message_id)
        return
    from app import tunnel

    title = "Mac / Linux" if kind == "mac" else "Windows (CMD ou PowerShell)"
    tip = (
        "Colle dans CMD ou PowerShell → Entrée. La fenêtre se ferme seule."
        if kind != "mac"
        else "Colle dans le Terminal."
    )
    forever = (
        "Lien permanent."
        if tunnel.is_stable_base()
        else "URL bot temporaire; HelperHost sur GitHub."
    )
    await _panel(
        client,
        chat_id,
        user_id,
        f"{title}\n\n{cmd}\n\n{tip}\n{forever}",
        {
            "inline_keyboard": [
                [
                    {"text": "🖥 Machines", "callback_data": "menu:machines"},
                    {"text": "🔗 Autre OS", "callback_data": "menu:connect"},
                ],
                [{"text": "« Menu", "callback_data": "menu:home"}],
            ]
        },
        message_id=message_id,
    )


async def ui_machines(
    client: httpx.AsyncClient,
    chat_id: int,
    user_id: int,
    *,
    message_id: int | None = None,
    mode: str = "use",
) -> None:
    sessions = store.list_sessions(owner_telegram_id=user_id)
    if not sessions:
        await _panel(
            client,
            chat_id,
            user_id,
            "Aucune machine.\nConnecter pour installer.",
            {
                "inline_keyboard": [
                    [{"text": "🔗 Connecter", "callback_data": "menu:connect"}],
                    [{"text": "« Menu", "callback_data": "menu:home"}],
                ]
            },
            message_id=message_id,
        )
        return

    lines = ["Choisis un terminal:" if mode == "use" else "Supprimer:"]
    rows: list[list[dict[str, str]]] = []
    active_id = store.telegram_get_binding(user_id).get("session_id")
    for s in sessions:
        raw = store.get_session(s["id"])
        online = await remote.pc_health(raw) if raw else False
        mark = "🟢" if online else "⚪"
        if s.get("wipe_pending"):
            mark = "🗑"
        star = " ✓" if s["id"] == active_id else ""
        pending = " (wipe…)" if s.get("wipe_pending") else ""
        lines.append(f"{mark} {s['name']}{star}{pending}")
        prefix = "use" if mode == "use" else "delask"
        label = f"{'▶ ' if mode == 'use' else '🗑 '}{s['name']}"
        rows.append([{"text": label[:64], "callback_data": f"{prefix}:{s['id']}"}])
    rows.append(
        [
            {
                "text": "🔄",
                "callback_data": f"menu:{'machines' if mode == 'use' else 'delete'}",
            },
            {"text": "« Menu", "callback_data": "menu:home"},
        ]
    )
    await _panel(
        client,
        chat_id,
        user_id,
        "\n".join(lines),
        {"inline_keyboard": rows},
        message_id=message_id,
    )


async def ui_status(
    client: httpx.AsyncClient,
    chat_id: int,
    user_id: int,
    *,
    message_id: int | None = None,
) -> None:
    binding = store.telegram_get_binding(user_id)
    sid = binding.get("session_id")
    if not sid:
        await _panel(
            client,
            chat_id,
            user_id,
            "Ouvre d’abord une machine.",
            {
                "inline_keyboard": [
                    [{"text": "🖥 Machines", "callback_data": "menu:machines"}],
                    [{"text": "« Menu", "callback_data": "menu:home"}],
                ]
            },
            message_id=message_id,
        )
        return
    owned = {x["id"]: x for x in store.list_sessions(owner_telegram_id=user_id)}
    if sid not in owned:
        await _panel(
            client, chat_id, user_id, "Session inconnue.", NAV_HOME, message_id=message_id
        )
        return
    raw = store.get_session(sid)
    online = await remote.pc_health(raw) if raw else False
    await _panel(
        client,
        chat_id,
        user_id,
        f"Machine: « {owned[sid]['name']} »\n"
        f"{'🟢 en ligne' if online else '⚪ hors ligne'}\n"
        "Session jusqu’à suppression.",
        _machine_keyboard(sid),
        message_id=message_id,
    )


async def ui_terminal_hint(
    client: httpx.AsyncClient,
    chat_id: int,
    user_id: int,
    *,
    message_id: int | None = None,
) -> None:
    binding = store.telegram_get_binding(user_id)
    sid = binding.get("session_id")
    name = _active_name(user_id)
    if not name or not sid:
        await _panel(
            client,
            chat_id,
            user_id,
            "Ouvre d’abord une machine pour le terminal.",
            {
                "inline_keyboard": [
                    [{"text": "🖥 Machines", "callback_data": "menu:machines"}]
                ]
            },
            message_id=message_id,
        )
        return
    await _panel(
        client,
        chat_id,
        user_id,
        f"Terminal — « {name} » uniquement\n"
        "Envoie une commande en message texte.\n"
        "Les outils / statut concernent aussi cette machine.",
        _machine_keyboard(sid),
        message_id=message_id,
    )


async def ui_tools(
    client: httpx.AsyncClient,
    chat_id: int,
    user_id: int,
    *,
    message_id: int | None = None,
) -> None:
    name = _active_name(user_id)
    if not name:
        await _panel(
            client,
            chat_id,
            user_id,
            "Sélectionne d’abord une machine Windows.",
            {
                "inline_keyboard": [
                    [{"text": "🖥 Machines", "callback_data": "menu:machines"}],
                    [{"text": "« Menu", "callback_data": "menu:home"}],
                ]
            },
            message_id=message_id,
        )
        return
    rows: list[list[dict[str, str]]] = []
    row: list[dict[str, str]] = []
    for t in TOOLS:
        row.append({"text": t["label"][:32], "callback_data": f"tool:{t['id']}"})
        if len(row) == 2:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    rows.append([{"text": "📦 Tous (zip)", "callback_data": "tool:all"}])
    sid = store.telegram_get_binding(user_id).get("session_id")
    rows.append(
        [
            {"text": "« Machine", "callback_data": f"use:{sid}" if sid else "menu:machines"},
            {"text": "« Menu", "callback_data": "menu:home"},
        ]
    )
    await _panel(
        client,
        chat_id,
        user_id,
        f"Outils — uniquement « {name} »\n"
        "Télécharge / exécute sur ce PC, puis envoie le fichier ici.",
        {"inline_keyboard": rows},
        message_id=message_id,
    )


async def do_run_tool(
    client: httpx.AsyncClient,
    chat_id: int,
    user_id: int,
    tool_id: str,
    *,
    message_id: int | None = None,
) -> None:
    binding = store.telegram_get_binding(user_id)
    sid = binding.get("session_id")
    if not sid:
        await _panel(
            client,
            chat_id,
            user_id,
            "Aucune machine active.",
            {
                "inline_keyboard": [
                    [{"text": "🖥 Machines", "callback_data": "menu:machines"}]
                ]
            },
            message_id=message_id,
        )
        return
    raw = store.get_session(sid)
    if not raw:
        await _panel(client, chat_id, user_id, "Session perdue.", NAV_INLINE, message_id=message_id)
        return
    if not pc_tools.is_windows_session(raw):
        await _panel(
            client,
            chat_id,
            user_id,
            "Ces outils sont Windows uniquement.",
            {
                "inline_keyboard": [
                    [{"text": "🖥 Machines", "callback_data": "menu:machines"}],
                    [{"text": "« Menu", "callback_data": "menu:home"}],
                ]
            },
            message_id=message_id,
        )
        return

    label = "Tous" if tool_id == "all" else (TOOLS_BY_ID.get(tool_id) or {}).get("label", tool_id)
    await _panel(
        client,
        chat_id,
        user_id,
        f"« {raw['name']} » — {label}…\nTéléchargement + export…",
        {"inline_keyboard": []},
        message_id=message_id,
    )
    mid = store.telegram_get_binding(user_id).get("ui_message_id")
    try:
        import base64 as b64mod

        async def _run_ps(ps: str, timeout: float = 180.0) -> str:
            # Prefer -File via tiny curl runner; EncodedCommand only if short.
            enc = b64mod.b64encode(ps.encode("utf-16le")).decode("ascii")
            if len(enc) <= 6000:
                cmd = f"powershell -NoProfile -WindowStyle Hidden -EncodedCommand {enc}"
            else:
                raise RuntimeError("commande trop longue pour Windows")
            result = await remote.pc_run(raw, cmd, timeout=timeout, record=False)
            out = str(result.get("output") or "")
            if int(result.get("exit_code") or 0) != 0 and "FILEB64:" not in out:
                raise RuntimeError(out.strip() or f"exit {result.get('exit_code')}")
            return out

        if tool_id == "all":
            out = await _run_ps(pc_tools.build_all_tools_ps(), timeout=300.0)
            fname, data = pc_tools.parse_file_b64(out)
            note = ""
        else:
            out = await _run_ps(pc_tools.build_tool_ps(tool_id), timeout=120.0)
            fname, data = pc_tools.parse_file_b64(out)
            note = ""

        ok = await _send_document(
            client,
            chat_id,
            data,
            fname,
            caption=f"{raw['name']} — {label}{note}",
        )
        if not ok:
            raise RuntimeError("envoi Telegram échoué")
        await _panel(
            client,
            chat_id,
            user_id,
            f"« {raw['name']} » — {label}\nFichier envoyé: {fname}{note}",
            {
                "inline_keyboard": [
                    [{"text": "🧰 Outils", "callback_data": "menu:tools"}],
                    [{"text": "« Menu", "callback_data": "menu:home"}],
                ]
            },
            message_id=mid,
        )
    except Exception as e:
        await _panel(
            client,
            chat_id,
            user_id,
            f"Échec {label}: {e}",
            {
                "inline_keyboard": [
                    [{"text": "🧰 Outils", "callback_data": "menu:tools"}],
                    [{"text": "« Menu", "callback_data": "menu:home"}],
                ]
            },
            message_id=mid,
        )


async def ui_confirm_delete(
    client: httpx.AsyncClient,
    chat_id: int,
    user_id: int,
    sid: str,
    *,
    message_id: int | None = None,
) -> None:
    s = store.get_session(sid)
    if not s or s.get("id") not in {
        x["id"] for x in store.list_sessions(owner_telegram_id=user_id)
    }:
        await _panel(
            client, chat_id, user_id, "Introuvable.", NAV_INLINE, message_id=message_id
        )
        return
    await _panel(
        client,
        chat_id,
        user_id,
        f"Supprimer « {s['name']} » ?\n"
        "Efface l’agent sur le PC (si en ligne) et retire la machine du bot.",
        {
            "inline_keyboard": [
                [
                    {"text": "✅ Confirmer", "callback_data": f"delok:{sid}"},
                    {"text": "❌ Annuler", "callback_data": "menu:delete"},
                ]
            ]
        },
        message_id=message_id,
    )


async def do_delete(
    client: httpx.AsyncClient,
    chat_id: int,
    user_id: int,
    sid: str,
    *,
    message_id: int | None = None,
) -> None:
    owned = {x["id"]: x for x in store.list_sessions(owner_telegram_id=user_id)}
    if sid not in owned:
        await _panel(
            client, chat_id, user_id, "Introuvable.", NAV_HOME, message_id=message_id
        )
        return
    name = owned[sid]["name"]
    raw = store.get_session(sid)
    await _panel(
        client,
        chat_id,
        user_id,
        f"Suppression de « {name} »…\nEffacement PC + restauration AV en cours.",
        {"inline_keyboard": []},
        message_id=message_id,
    )
    mid = store.telegram_get_binding(user_id).get("ui_message_id")
    store.mark_wipe_pending(sid)
    started = False
    if raw:
        try:
            started = await remote.pc_shutdown(raw)
        except Exception:
            started = False

    if started:
        await _panel(
            client,
            chat_id,
            user_id,
            f"« {name} » — effacement lancé sur le PC.\n"
            "Tu recevras une notification quand ce sera terminé\n"
            "(AV remis à la normale, traces effacées).",
            NAV_HOME,
            message_id=mid,
        )
        await notify_owner(
            user_id,
            f"⏳ « {name} » — suppression en cours sur le PC…",
        )
    else:
        await _panel(
            client,
            chat_id,
            user_id,
            f"« {name} » — PC offline.\n"
            "Wipe + restauration AV dès que le PC se reconnecte.\n"
            "Notification à la fin.",
            NAV_HOME,
            message_id=mid,
        )
        await notify_owner(
            user_id,
            f"⏳ « {name} » — en attente du PC pour terminer la suppression.",
        )


async def notify_owner(user_id: int, text: str) -> None:
    if not config.TELEGRAM_BOT_TOKEN or not user_id:
        return
    try:
        async with httpx.AsyncClient() as client:
            await _send(client, int(user_id), text)
    except Exception:
        log.exception("notify_owner %s", user_id)


async def retry_pending_wipes(client: httpx.AsyncClient) -> None:
    from app import tunnel

    for s in store.list_wipe_pending():
        sid = s["id"]
        name = s.get("name") or "?"
        owner = None
        raw_full = store.get_session_raw(sid)
        if raw_full:
            owner = raw_full.get("owner_telegram_id")
        wiped = await remote.pc_shutdown(s)
        if not wiped:
            continue
        await asyncio.sleep(2)
        if not store.get_session_raw(sid):
            continue
        done = store.delete_session(sid)
        tunnel.maybe_stop_tunnel_if_idle()
        if owner and done:
            await _send(
                client,
                int(owner),
                f"✅ « {name} » — suppression terminée.\n"
                "AV remis à la normale · traces PC effacées.",
            )


async def do_select(
    client: httpx.AsyncClient,
    chat_id: int,
    user_id: int,
    sid: str,
    *,
    message_id: int | None = None,
) -> None:
    owned = {x["id"]: x for x in store.list_sessions(owner_telegram_id=user_id)}
    if sid not in owned:
        await _panel(
            client, chat_id, user_id, "Introuvable.", NAV_HOME, message_id=message_id
        )
        return
    store.telegram_set_session(user_id, sid)
    raw = store.get_session(sid)
    online = await remote.pc_health(raw) if raw else False
    name = owned[sid]["name"]
    await _panel(
        client,
        chat_id,
        user_id,
        f"Machine: « {name} »\n"
        f"{'🟢 En ligne — envoie une commande texte = terminal.' if online else '⚪ Hors ligne (session gardée).'}\n\n"
        "Tout ci-dessous concerne UNIQUEMENT cette machine.",
        _machine_keyboard(sid),
        message_id=message_id,
    )


async def run_shell(client: httpx.AsyncClient, chat_id: int, user_id: int, text: str) -> None:
    binding = store.telegram_get_binding(user_id)
    sid = binding.get("session_id")
    if not sid:
        await _panel(
            client,
            chat_id,
            user_id,
            "Aucun terminal actif.",
            {
                "inline_keyboard": [
                    [{"text": "🖥 Machines", "callback_data": "menu:machines"}]
                ]
            },
        )
        return
    owned_ids = {x["id"] for x in store.list_sessions(owner_telegram_id=user_id)}
    if sid not in owned_ids:
        await _send(client, chat_id, "Session invalide.")
        return
    raw = store.get_session(sid)
    if not raw:
        await _send(client, chat_id, "Session perdue.")
        return
    # Shell I/O = separate messages (not the nav panel)
    status_id = await _send(client, chat_id, f"[{raw['name']}] › {text}\n…")
    try:
        result = await remote.pc_run(raw, text)
    except Exception as e:
        msg = f"[{raw['name']}] › {text}\nPC injoignable: {e}"
        if status_id:
            await _edit(client, chat_id, status_id, msg)
        else:
            await _send(client, chat_id, msg)
        return
    out = result.get("output") or "(vide)"
    ec = result.get("exit_code")
    body = f"[{raw['name']}] › {text}\nexit {ec}\n{out}"
    if status_id:
        await _edit(client, chat_id, status_id, body)
    else:
        await _send(client, chat_id, body)


def _is_nav_text(text: str) -> str | None:
    t = text.strip()
    mapping = {
        "🖥 Machines": "machines",
        "Machines": "machines",
        "🔗 Connecter": "connect",
        "Connecter": "connect",
        "📡 Status": "status",
        "Status": "status",
        "⌨️ Terminal": "terminal",
        "Terminal": "terminal",
        "🗑 Supprimer": "delete",
        "Supprimer": "delete",
        "🧰 Outils": "tools",
        "Outils": "tools",
        "☰ Menu": "home",
        "Menu": "home",
    }
    return mapping.get(t)


async def dispatch_menu(
    client: httpx.AsyncClient,
    chat_id: int,
    user_id: int,
    action: str,
    *,
    message_id: int | None = None,
) -> None:
    if action == "home":
        await ui_home(client, chat_id, user_id, message_id=message_id)
    elif action == "connect":
        await ui_connect(client, chat_id, user_id, message_id=message_id)
    elif action == "machines":
        await ui_machines(client, chat_id, user_id, message_id=message_id, mode="use")
    elif action == "delete":
        await ui_machines(client, chat_id, user_id, message_id=message_id, mode="delete")
    elif action == "status":
        await ui_status(client, chat_id, user_id, message_id=message_id)
    elif action == "terminal":
        await ui_terminal_hint(client, chat_id, user_id, message_id=message_id)
    elif action == "tools":
        await ui_tools(client, chat_id, user_id, message_id=message_id)
    else:
        await ui_home(client, chat_id, user_id, message_id=message_id)


async def _handle_callback(client: httpx.AsyncClient, cq: dict[str, Any]) -> None:
    data = (cq.get("data") or "").strip()
    cq_id = str(cq.get("id") or "")
    msg = cq.get("message") or {}
    chat_id = int((msg.get("chat") or {}).get("id") or 0)
    user_id = int((cq.get("from") or {}).get("id") or 0)
    message_id = int(msg.get("message_id") or 0) or None
    if not chat_id or not user_id or not data:
        return
    if not _allowed(user_id):
        await _answer_cb(client, cq_id, "Accès refusé", show_alert=True)
        return

    await _answer_cb(client, cq_id)
    if message_id:
        store.telegram_set_ui_message(user_id, message_id)

    if data.startswith("menu:"):
        await dispatch_menu(
            client, chat_id, user_id, data.split(":", 1)[1], message_id=message_id
        )
        return
    if data.startswith("conn:"):
        await ui_show_install_cmd(
            client, chat_id, user_id, data.split(":", 1)[1], message_id=message_id
        )
        return
    if data.startswith("use:"):
        await do_select(
            client, chat_id, user_id, data.split(":", 1)[1], message_id=message_id
        )
        return
    if data.startswith("delask:"):
        await ui_confirm_delete(
            client, chat_id, user_id, data.split(":", 1)[1], message_id=message_id
        )
        return
    if data.startswith("delok:"):
        await do_delete(
            client, chat_id, user_id, data.split(":", 1)[1], message_id=message_id
        )
        return
    if data.startswith("tool:"):
        await do_run_tool(
            client, chat_id, user_id, data.split(":", 1)[1], message_id=message_id
        )
        return


async def _handle_message(client: httpx.AsyncClient, message: dict[str, Any]) -> None:
    chat = message.get("chat") or {}
    user = message.get("from") or {}
    chat_id = int(chat.get("id") or 0)
    user_id = int(user.get("id") or 0)
    text = (message.get("text") or "").strip()
    if not chat_id or not text:
        return
    if not _allowed(user_id):
        await _send(
            client,
            chat_id,
            "Bot privé — accès refusé.\n"
            f"(ton id: {user_id})",
            reply_markup=REMOVE_KEYBOARD,
        )
        return

    low = text.lower().split("@")[0].strip()
    if low in ("/start", "/help", "/menu"):
        store.telegram_set_ui_message(user_id, None)
        # Remove old bottom keyboard (separate msg), then delete it to avoid spam
        rid = await _send(client, chat_id, "…", reply_markup=REMOVE_KEYBOARD)
        if rid:
            await _api(client, "deleteMessage", chat_id=chat_id, message_id=rid)
        await ui_home(client, chat_id, user_id, force_new=True)
        return
    if low == "/whoami":
        await _send(client, chat_id, f"Ton user id: {user_id}")
        return

    nav = _is_nav_text(text)
    if nav:
        await dispatch_menu(client, chat_id, user_id, nav)
        return

    await run_shell(client, chat_id, user_id, text)


async def telegram_loop() -> None:
    if not config.TELEGRAM_BOT_TOKEN:
        return
    log.info("Telegram bot starting (panel UI)")
    offset = 0
    last_wipe_retry = 0.0
    async with httpx.AsyncClient() as client:
        me = await _api(client, "getMe")
        if me.get("ok"):
            log.info("Bot @%s", (me.get("result") or {}).get("username"))
        await _api(
            client,
            "setMyCommands",
            commands=[
                {"command": "start", "description": "Ouvrir le menu"},
                {"command": "menu", "description": "Menu AgentShe"},
            ],
        )
        while True:
            try:
                import time as _time

                now = _time.time()
                if now - last_wipe_retry >= 20:
                    last_wipe_retry = now
                    try:
                        await retry_pending_wipes(client)
                    except Exception:
                        log.exception("retry_pending_wipes")

                data = await _api(
                    client,
                    "getUpdates",
                    offset=offset,
                    timeout=30,
                    allowed_updates=["message", "callback_query"],
                )
                for upd in data.get("result") or []:
                    offset = max(offset, int(upd.get("update_id", 0)) + 1)
                    try:
                        if "callback_query" in upd:
                            await _handle_callback(client, upd["callback_query"])
                        elif "message" in upd:
                            await _handle_message(client, upd["message"])
                    except Exception:
                        log.exception("handle update")
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("telegram loop")
                await asyncio.sleep(3)
