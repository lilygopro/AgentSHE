#!/usr/bin/env python3
import json
import time
import urllib.request

BASE = "http://127.0.0.1:8787"
KEY = "agentshe-local"


def req(method, path, body=None, admin=False):
    data = None if body is None else json.dumps(body).encode()
    headers = {"Content-Type": "application/json"} if body is not None else {}
    if admin:
        headers["X-Admin-Key"] = KEY
    r = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(r, timeout=30) as resp:
        return json.loads(resp.read().decode())


def main():
    s = req(
        "POST",
        "/api/sessions",
        {"name": "WSL Local", "platform": "linux"},
        admin=True,
    )["session"]
    token, sid = s["token"], s["id"]
    print("session", sid)
    script = urllib.request.urlopen(
        f"{BASE}/agent?action=script-sh&token={token}", timeout=30
    ).read().decode()
    open("/tmp/agentshe_install.sh", "w").write(script)
    import subprocess

    out = subprocess.check_output(["bash", "/tmp/agentshe_install.sh"], text=True)
    print("install", out.strip())
    time.sleep(2)
    s2 = req("GET", f"/api/sessions/{sid}", admin=True)["session"]
    print("online", s2["online"], s2.get("agent"))
    q = req(
        "POST",
        f"/api/sessions/{sid}/enqueue",
        {"command": "uname -a; whoami; pwd"},
        admin=True,
    )
    print("queued", q)
    for _ in range(20):
        time.sleep(0.5)
        h = req("GET", f"/api/sessions/{sid}", admin=True)["session"]["history"]
        hit = next((x for x in h if x["id"] == q["cmd_id"] and x.get("done")), None)
        if hit:
            print("RESULT:")
            print(hit["output"])
            print("exit", hit["exit_code"])
            return
    print("TIMEOUT")


if __name__ == "__main__":
    main()
