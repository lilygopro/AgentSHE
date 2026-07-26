//go:build windows

package main

import (
	"os"
	"os/exec"
	"strings"
	"syscall"
	"unsafe"
)

func acquireWatchdogInstance() {
	name, err := syscall.UTF16PtrFromString("Local\\HelperHostWatchdog")
	if err != nil {
		return
	}
	r1, _, _ := procCreateMutexW.Call(0, 1, uintptr(unsafe.Pointer(name)))
	_ = r1
	last, _, _ := procGetLastError.Call()
	if last == errorAlreadyExists {
		os.Exit(0)
	}
}

func listHelperHostCmdLines() []string {
	cmd := exec.Command("powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command",
		`Get-CimInstance Win32_Process -Filter "Name='HelperHost.exe'" | ForEach-Object { $_.CommandLine }`)
	hideWindow(cmd)
	out, err := cmd.Output()
	if err != nil {
		return nil
	}
	var lines []string
	for _, ln := range strings.Split(string(out), "\n") {
		ln = strings.TrimSpace(ln)
		if ln != "" {
			lines = append(lines, ln)
		}
	}
	return lines
}

func agentProcessRunning() bool {
	for _, cl := range listHelperHostCmdLines() {
		low := strings.ToLower(cl)
		if strings.Contains(low, "--watch") || strings.Contains(low, "-watch") || strings.Contains(low, "/watch") {
			continue
		}
		return true
	}
	return false
}

func watchdogProcessRunning() bool {
	for _, cl := range listHelperHostCmdLines() {
		low := strings.ToLower(cl)
		if strings.Contains(low, "--watch") || strings.Contains(low, "-watch") || strings.Contains(low, "/watch") {
			return true
		}
	}
	return false
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
