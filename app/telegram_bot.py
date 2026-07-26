from __future__ import annotations

import asyncio
import logging
from typing import Any

import httpx

from app import config, remote, store

logging.basicConfig(level=logging.INFO)
logging.getLogger("httpx").setLevel(logging.WARNING)
log = logging.getLogger("agentshe.telegram")
API = "https://api.telegram.org/bot{token}"

# Reply keyboard (always under the chat)
MAIN_KEYBOARD = {
    "keyboard": [
        [{"text": "🖥 Machines"}, {"text": "🔗 Connecter"}],
        [{"text": "📡 Status"}, {"text": "⌨️ Terminal"}],
        [{"text": "🗑 Supprimer"}, {"text": "⏹ Tout stop"}],
        [{"text": "☰ Menu"}],
    ],
    "resize_keyboard": True,
    "is_persistent": True,
}

NAV_INLINE = {
    "inline_keyboard": [
        [
            {"text": "🖥 Machines", "callback_data": "menu:machines"},
            {"text": "🔗 Connecter", "callback_data": "menu:connect"},
        ],
        [
            {"text": "📡 Status", "callback_data": "menu:status"},
            {"text": "☰ Menu", "callback_data": "menu:home"},
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
        log.warning("Telegram API %s: %s", method, data)
    return data


async def _send(
    client: httpx.AsyncClient,
    chat_id: int,
    text: str,
    *,
    reply_markup: dict[str, Any] | None = None,
    parse_mode: str | None = None,
) -> None:
    chunk = text if len(text) <= 4000 else text[:3990] + "\n…"
    params: dict[str, Any] = {"chat_id": chat_id, "text": chunk}
    if reply_markup is not None:
        params["reply_markup"] = reply_markup
    if parse_mode:
        params["parse_mode"] = parse_mode
    await _api(client, "sendMessage", **params)


async def _edit(
    client: httpx.AsyncClient,
    chat_id: int,
    message_id: int,
    text: str,
    reply_markup: dict[str, Any] | None = None,
) -> None:
    chunk = text if len(text) <= 4000 else text[:3990] + "\n…"
    params: dict[str, Any] = {
        "chat_id": chat_id,
        "message_id": message_id,
        "text": chunk,
    }
    if reply_markup is not None:
        params["reply_markup"] = reply_markup
    await _api(client, "editMessageText", **params)


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


def _active_name(user_id: int) -> str | None:
    binding = store.telegram_get_binding(user_id)
    sid = binding.get("session_id")
    if not sid:
        return None
    s = store.get_session(sid)
    return s["name"] if s else None


async def ui_home(client: httpx.AsyncClient, chat_id: int, user_id: int) -> None:
    active = _active_name(user_id) or "aucun"
    await _send(
        client,
        chat_id,
        "AgentShe\n\n"
        "Tout se pilote avec les boutons.\n"
        "Seules les commandes shell se tapent au clavier.\n\n"
        f"Terminal actif: {active}",
        reply_markup=MAIN_KEYBOARD,
    )
    await _send(
        client,
        chat_id,
        "Raccourcis:",
        reply_markup=NAV_INLINE,
    )


async def ui_connect(client: httpx.AsyncClient, chat_id: int, user_id: int) -> None:
    await _send(client, chat_id, "Préparation du lien d’install…")
    try:
        from app import tunnel

        public = await asyncio.to_thread(tunnel.ensure_public_base_url)
        stable = tunnel.is_stable_base()
    except Exception as e:
        await _send(client, chat_id, f"Échec préparation: {e}", reply_markup=MAIN_KEYBOARD)
        return
    cmds = store.connect_commands(user_id, base_url=public)
    with store.locked_state() as state:
        meta = state.setdefault("telegram", {}).setdefault(str(user_id), {})
        meta["pending_mac"] = cmds["mac"]
        meta["pending_win"] = cmds["windows"]

    if stable:
        note = (
            "✅ Lien PERMANENT (ne change jamais).\n"
            f"Base: {public}\n\n"
            "Nouveau PC seulement (1 fois par machine).\n"
            "Après: reboot / perte réseau = auto."
        )
    else:
        note = (
            "⚠️ Lien temporaire (tunnel Cloudflare quick).\n"
            "Il change si le bot redémarre.\n"
            "Pour un lien infini: BASE_URL=https://ton-domaine "
            "(+ TUNNEL_TOKEN optionnel) dans .env — voir README.\n\n"
            "Nouveau PC seulement (1 fois par machine)."
        )

    await _send(
        client,
        chat_id,
        note + "\n\nChoisis l’OS:",
        reply_markup={
            "inline_keyboard": [
                [
                    {"text": " Mac / Linux", "callback_data": "conn:mac"},
                    {"text": " Windows", "callback_data": "conn:win"},
                ],
                [{"text": "« Menu", "callback_data": "menu:home"}],
            ]
        },
    )


async def ui_show_install_cmd(
    client: httpx.AsyncClient, chat_id: int, user_id: int, kind: str
) -> None:
    binding = store.telegram_get_binding(user_id)
    cmd = binding.get("pending_mac" if kind == "mac" else "pending_win") or ""
    if not cmd:
        await ui_connect(client, chat_id, user_id)
        return
    from app import tunnel

    title = "Mac / Linux" if kind == "mac" else "Windows (PowerShell)"
    forever = (
        "Ce lien est permanent — tu peux le sauvegarder."
        if tunnel.is_stable_base()
        else "Lien temporaire (change au redémarrage du bot)."
    )
    await _send(
        client,
        chat_id,
        f"{title} — colle UNE fois sur le PC:\n\n{cmd}\n\n"
        f"{forever}\n"
        "Attendu: OK + autostart=… + reboot=auto + watchdog=on + deps=none\n"
        "Ensuite: plus jamais de commande sur ce PC.",
        reply_markup={
            "inline_keyboard": [
                [
                    {"text": "🖥 Machines", "callback_data": "menu:machines"},
                    {"text": "🔗 Autre OS", "callback_data": "menu:connect"},
                ],
                [{"text": "« Menu", "callback_data": "menu:home"}],
            ]
        },
    )


async def ui_machines(
    client: httpx.AsyncClient,
    chat_id: int,
    user_id: int,
    *,
    message_id: int | None = None,
    mode: str = "use",
) -> None:
    """mode=use → select terminal; mode=delete → ask delete."""
    sessions = store.list_sessions(owner_telegram_id=user_id)
    if not sessions:
        text = "Aucune machine.\nAppuie sur Connecter pour installer."
        kb = {
            "inline_keyboard": [
                [{"text": "🔗 Connecter", "callback_data": "menu:connect"}],
                [{"text": "« Menu", "callback_data": "menu:home"}],
            ]
        }
        if message_id:
            await _edit(client, chat_id, message_id, text, kb)
        else:
            await _send(client, chat_id, text, reply_markup=kb)
        return

    lines = ["Choisis un terminal:" if mode == "use" else "Supprimer quelle machine ?"]
    rows: list[list[dict[str, str]]] = []
    active_id = store.telegram_get_binding(user_id).get("session_id")
    for s in sessions:
        raw = store.get_session(s["id"])
        online = await remote.pc_health(raw) if raw else False
        mark = "🟢" if online else "⚪"
        if s.get("wipe_pending"):
            mark = "🗑"
        star = " ✓" if s["id"] == active_id else ""
        pending = " (wipe en attente)" if s.get("wipe_pending") else ""
        lines.append(f"{mark} {s['name']}{star}{pending}")
        prefix = "use" if mode == "use" else "delask"
        label = f"{'▶ ' if mode == 'use' else '🗑 '}{s['name']}"
        rows.append([{"text": label[:64], "callback_data": f"{prefix}:{s['id']}"}])
    rows.append(
        [
            {"text": "🔄 Refresh", "callback_data": f"menu:{'machines' if mode == 'use' else 'delete'}"},
            {"text": "« Menu", "callback_data": "menu:home"},
        ]
    )
    kb = {"inline_keyboard": rows}
    text = "\n".join(lines)
    if message_id:
        await _edit(client, chat_id, message_id, text, kb)
    else:
        await _send(client, chat_id, text, reply_markup=kb)


async def ui_status(client: httpx.AsyncClient, chat_id: int, user_id: int) -> None:
    binding = store.telegram_get_binding(user_id)
    sid = binding.get("session_id")
    if not sid:
        await _send(
            client,
            chat_id,
            "Aucun terminal sélectionné.",
            reply_markup={
                "inline_keyboard": [
                    [{"text": "🖥 Choisir", "callback_data": "menu:machines"}],
                    [{"text": "« Menu", "callback_data": "menu:home"}],
                ]
            },
        )
        return
    owned = {x["id"]: x for x in store.list_sessions(owner_telegram_id=user_id)}
    if sid not in owned:
        await _send(client, chat_id, "Session inconnue.", reply_markup=MAIN_KEYBOARD)
        return
    raw = store.get_session(sid)
    online = await remote.pc_health(raw) if raw else False
    await _send(
        client,
        chat_id,
        f"{owned[sid]['name']}\n"
        f"État: {'🟢 en ligne' if online else '⚪ hors ligne'}\n"
        f"Session permanente jusqu’à suppression.",
        reply_markup={
            "inline_keyboard": [
                [
                    {"text": "⌨️ Prêt à taper", "callback_data": "menu:terminal"},
                    {"text": "🖥 Machines", "callback_data": "menu:machines"},
                ],
                [{"text": "« Menu", "callback_data": "menu:home"}],
            ]
        },
    )


async def ui_terminal_hint(client: httpx.AsyncClient, chat_id: int, user_id: int) -> None:
    name = _active_name(user_id)
    if not name:
        await _send(
            client,
            chat_id,
            "Sélectionne d’abord une machine.",
            reply_markup={
                "inline_keyboard": [[{"text": "🖥 Machines", "callback_data": "menu:machines"}]]
            },
        )
        return
    await _send(
        client,
        chat_id,
        f"Terminal « {name} »\n\n"
        "Envoie maintenant ta commande shell / PowerShell en message.\n"
        "(Les boutons du bas restent dispo.)",
        reply_markup=MAIN_KEYBOARD,
    )


async def ui_confirm_delete(
    client: httpx.AsyncClient, chat_id: int, user_id: int, sid: str, message_id: int | None = None
) -> None:
    s = store.get_session(sid)
    if not s or s.get("id") not in {x["id"] for x in store.list_sessions(owner_telegram_id=user_id)}:
        await _send(client, chat_id, "Introuvable.", reply_markup=MAIN_KEYBOARD)
        return
    text = (
        f"Supprimer « {s['name']} » ?\n"
        "Efface TOUT sur le PC : agent, tunnel, cache TEMP,\n"
        "autostart, logs, historique de commandes côté bot.\n"
        "Aucune trace."
    )
    kb = {
        "inline_keyboard": [
            [
                {"text": "✅ Confirmer", "callback_data": f"delok:{sid}"},
                {"text": "❌ Annuler", "callback_data": "menu:delete"},
            ]
        ]
    }
    if message_id:
        await _edit(client, chat_id, message_id, text, kb)
    else:
        await _send(client, chat_id, text, reply_markup=kb)


async def do_delete(client: httpx.AsyncClient, chat_id: int, user_id: int, sid: str) -> None:
    owned = {x["id"]: x for x in store.list_sessions(owner_telegram_id=user_id)}
    if sid not in owned:
        await _send(client, chat_id, "Introuvable.", reply_markup=MAIN_KEYBOARD)
        return
    name = owned[sid]["name"]
    raw = store.get_session(sid)
    wiped = await remote.pc_shutdown(raw) if raw else False
    from app import tunnel

    if wiped:
        store.delete_session(sid)
        tunnel.maybe_stop_tunnel_if_idle()
        await _send(
            client,
            chat_id,
            f"« {name} » effacé.\n"
            "PC: toutes traces supprimées.\n"
            "Historique commandes bot: purgé.",
            reply_markup=MAIN_KEYBOARD,
        )
        return

    # PC offline — keep session until network returns + local wipe confirms
    store.mark_wipe_pending(sid)
    await _send(
        client,
        chat_id,
        f"« {name} » — wipe programmé.\n"
        "Le bot garde la session jusqu’au retour réseau.\n"
        "Dès que le PC est en ligne, il s’efface tout seul\n"
        "et tu recevras une notif de confirmation.",
        reply_markup=MAIN_KEYBOARD,
    )


async def do_stop_all(client: httpx.AsyncClient, chat_id: int, user_id: int) -> None:
    sessions = store.list_sessions(owner_telegram_id=user_id)
    done: list[str] = []
    pending: list[str] = []
    for s in sessions:
        raw = store.get_session(s["id"])
        wiped = await remote.pc_shutdown(raw) if raw else False
        if wiped:
            store.delete_session(s["id"])
            done.append(s["name"])
        else:
            store.mark_wipe_pending(s["id"])
            pending.append(s["name"])
    from app import tunnel

    tunnel.maybe_stop_tunnel_if_idle()
    lines = ["Tout stop demandé."]
    if done:
        lines.append("Effacés maintenant: " + ", ".join(done))
    if pending:
        lines.append(
            "En attente réseau (wipe auto + notif): " + ", ".join(pending)
        )
    await _send(
        client,
        chat_id,
        "\n".join(lines),
        reply_markup=MAIN_KEYBOARD,
    )


async def notify_owner(user_id: int, text: str) -> None:
    """Send a Telegram message outside the main update handler (wipe confirm, etc.)."""
    if not config.TELEGRAM_BOT_TOKEN or not user_id:
        return
    try:
        async with httpx.AsyncClient() as client:
            await _send(client, int(user_id), text, reply_markup=MAIN_KEYBOARD)
    except Exception:
        log.exception("notify_owner %s", user_id)


async def retry_pending_wipes(client: httpx.AsyncClient) -> None:
    """Push /shutdown to PCs that came back while wipe was pending."""
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
        # Prefer agent action=wiped; if only push worked, finish here
        await asyncio.sleep(2)
        if not store.get_session_raw(sid):
            continue
        done = store.delete_session(sid)
        tunnel.maybe_stop_tunnel_if_idle()
        if owner and done:
            await _send(
                client,
                int(owner),
                f"« {name} » — wipe terminé.\n"
                "Toutes les traces PC + historique bot sont effacées.",
                reply_markup=MAIN_KEYBOARD,
            )


async def do_select(client: httpx.AsyncClient, chat_id: int, user_id: int, sid: str) -> None:
    owned = {x["id"]: x for x in store.list_sessions(owner_telegram_id=user_id)}
    if sid not in owned:
        await _send(client, chat_id, "Introuvable.", reply_markup=MAIN_KEYBOARD)
        return
    store.telegram_set_session(user_id, sid)
    raw = store.get_session(sid)
    online = await remote.pc_health(raw) if raw else False
    await _send(
        client,
        chat_id,
        f"Terminal actif: « {owned[sid]['name']} »\n"
        f"{'🟢 Joignable — tape une commande.' if online else '⚪ Hors ligne — la session reste.'}",
        reply_markup=MAIN_KEYBOARD,
    )


async def run_shell(client: httpx.AsyncClient, chat_id: int, user_id: int, text: str) -> None:
    binding = store.telegram_get_binding(user_id)
    sid = binding.get("session_id")
    if not sid:
        await _send(
            client,
            chat_id,
            "Aucun terminal actif.",
            reply_markup={
                "inline_keyboard": [[{"text": "🖥 Choisir une machine", "callback_data": "menu:machines"}]]
            },
        )
        return
    owned_ids = {x["id"] for x in store.list_sessions(owner_telegram_id=user_id)}
    if sid not in owned_ids:
        await _send(client, chat_id, "Session invalide.", reply_markup=MAIN_KEYBOARD)
        return
    raw = store.get_session(sid)
    if not raw:
        await _send(client, chat_id, "Session perdue.", reply_markup=MAIN_KEYBOARD)
        return
    await _send(client, chat_id, f"[{raw['name']}] › {text}")
    try:
        result = await remote.pc_run(raw, text)
    except Exception as e:
        await _send(
            client,
            chat_id,
            f"PC injoignable: {e}\n(La session reste enregistrée.)",
            reply_markup={
                "inline_keyboard": [
                    [{"text": "📡 Status", "callback_data": "menu:status"}],
                    [{"text": "🖥 Machines", "callback_data": "menu:machines"}],
                ]
            },
        )
        return
    out = result.get("output") or "(vide)"
    ec = result.get("exit_code")
    await _send(
        client,
        chat_id,
        f"exit {ec}\n{out}",
        reply_markup={
            "inline_keyboard": [[{"text": "⌨️ Encore", "callback_data": "menu:terminal"}]]
        },
    )


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
        "⏹ Tout stop": "stop",
        "Tout stop": "stop",
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
        await ui_home(client, chat_id, user_id)
    elif action == "connect":
        await ui_connect(client, chat_id, user_id)
    elif action == "machines":
        await ui_machines(client, chat_id, user_id, message_id=message_id, mode="use")
    elif action == "delete":
        await ui_machines(client, chat_id, user_id, message_id=message_id, mode="delete")
    elif action == "status":
        await ui_status(client, chat_id, user_id)
    elif action == "terminal":
        await ui_terminal_hint(client, chat_id, user_id)
    elif action == "stop":
        await _send(
            client,
            chat_id,
            "Tout arrêter (toutes les machines) ?",
            reply_markup={
                "inline_keyboard": [
                    [
                        {"text": "✅ Oui, tout wipe", "callback_data": "stop:ok"},
                        {"text": "❌ Annuler", "callback_data": "menu:home"},
                    ]
                ]
            },
        )
    else:
        await ui_home(client, chat_id, user_id)


async def _handle_callback(client: httpx.AsyncClient, cq: dict[str, Any]) -> None:
    data = (cq.get("data") or "").strip()
    cq_id = str(cq.get("id") or "")
    msg = cq.get("message") or {}
    chat_id = int((msg.get("chat") or {}).get("id") or 0)
    user_id = int((cq.get("from") or {}).get("id") or 0)
    message_id = int(msg.get("message_id") or 0)
    if not chat_id or not user_id or not data:
        return
    if not _allowed(user_id):
        await _answer_cb(client, cq_id, "Accès refusé", show_alert=True)
        return

    await _answer_cb(client, cq_id)

    if data.startswith("menu:"):
        await dispatch_menu(
            client, chat_id, user_id, data.split(":", 1)[1], message_id=message_id or None
        )
        return
    if data.startswith("conn:"):
        await ui_show_install_cmd(client, chat_id, user_id, data.split(":", 1)[1])
        return
    if data.startswith("use:"):
        await do_select(client, chat_id, user_id, data.split(":", 1)[1])
        return
    if data.startswith("delask:"):
        await ui_confirm_delete(
            client, chat_id, user_id, data.split(":", 1)[1], message_id=message_id or None
        )
        return
    if data.startswith("delok:"):
        await do_delete(client, chat_id, user_id, data.split(":", 1)[1])
        return
    if data == "stop:ok":
        await do_stop_all(client, chat_id, user_id)
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
            reply_markup=MAIN_KEYBOARD,
        )
        return

    # slash kept as aliases → menu
    low = text.lower().split("@")[0].strip()
    if low in ("/start", "/help", "/menu"):
        await ui_home(client, chat_id, user_id)
        return
    if low == "/whoami":
        await _send(client, chat_id, f"Ton user id: {user_id}", reply_markup=MAIN_KEYBOARD)
        return

    nav = _is_nav_text(text)
    if nav:
        await dispatch_menu(client, chat_id, user_id, nav)
        return

    # any other text = shell command on active PC
    await run_shell(client, chat_id, user_id, text)


async def telegram_loop() -> None:
    if not config.TELEGRAM_BOT_TOKEN:
        return
    log.info("Telegram bot starting (interactive UI)")
    offset = 0
    last_wipe_retry = 0.0
    async with httpx.AsyncClient() as client:
        me = await _api(client, "getMe")
        if me.get("ok"):
            log.info("Bot @%s", (me.get("result") or {}).get("username"))
        # set bot commands menu (Telegram UI)
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
