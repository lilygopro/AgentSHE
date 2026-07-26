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
	// Embedded watchdog: HelperHost --watch (no sidecar .sh in install dir)
	exe := helperPath
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
    <string>%s</string><string>--watch</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Background</string>
  <key>WorkingDirectory</key><string>%s</string>
</dict></plist>
`, label, exe, dir)
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
ExecStart=%s --watch
Restart=always
RestartSec=5
[Install]
WantedBy=default.target
`, exe)), 0o644)
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
