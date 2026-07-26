//go:build !windows

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

func stateFilePath() string {
	return filepath.Join(dir, ".state")
}

func readStateStore() agentState {
	b, err := os.ReadFile(stateFilePath())
	if err != nil {
		return agentState{}
	}
	var st agentState
	_ = json.Unmarshal(b, &st)
	return st
}

func writeStateStore(st agentState) {
	raw, err := json.Marshal(st)
	if err != nil {
		return
	}
	_ = os.WriteFile(stateFilePath(), raw, 0o600)
	hidePath(stateFilePath())
}

func clearStateStore() {
	_ = os.Remove(stateFilePath())
}
