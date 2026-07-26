from __future__ import annotations

TOOLS: list[dict[str, str]] = [
    {"id": "chromepass", "label": "ChromePass", "exe": "ChromePass.exe"},
    {"id": "webbrowser", "label": "WebBrowserPassView", "exe": "WebBrowserPassView.exe"},
    {
        "id": "passwordfox",
        "label": "PasswordFox",
        "exe": "PasswordFox.exe",
        "exe_x64": "x64/PasswordFox.exe",
    },
    {"id": "mailpv", "label": "mailpv", "exe": "mailpv.exe"},
    {"id": "mspass", "label": "mspass", "exe": "mspass.exe"},
    {
        "id": "netpass",
        "label": "netpass",
        "exe": "netpass.exe",
        "exe_x64": "x64/netpass.exe",
    },
    {"id": "iepv", "label": "iepv", "exe": "iepv.exe"},
    {"id": "dialupass", "label": "Dialupass", "exe": "Dialupass.exe"},
    {"id": "pstpassword", "label": "PstPassword", "exe": "PstPassword.exe"},
]

TOOLS_BY_ID = {t["id"]: t for t in TOOLS}
