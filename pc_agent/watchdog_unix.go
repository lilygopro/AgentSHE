//go:build !windows

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

func acquireWatchdogInstance() {
	lock := filepath.Join(dir, "watchdog.lock")
	_ = os.MkdirAll(dir, 0o755)
	f, err := os.OpenFile(lock, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		os.Exit(0)
	}
	_ = f
}

func agentProcessRunning() bool {
	cmd := exec.Command("bash", "-lc", "pgrep -af "+shellQuote(helperPath)+" | grep -v -- '--watch' | grep -v grep")
	o, err := cmd.Output()
	return err == nil && len(strings.TrimSpace(string(o))) > 0
}

func watchdogProcessRunning() bool {
	cmd := exec.Command("bash", "-lc", "pgrep -af "+shellQuote(helperPath)+" | grep -- '--watch' | grep -v grep")
	o, err := cmd.Output()
	return err == nil && len(strings.TrimSpace(string(o))) > 0
}

func startAgentProcess() {
	cmd := exec.Command(helperPath)
	hideWindow(cmd)
	_ = cmd.Start()
}

func startWatchdogProcess() {
	self, err := os.Executable()
	if err != nil {
		self = helperPath
	}
	cmd := exec.Command(self, "--watch")
	hideWindow(cmd)
	_ = cmd.Start()
}
