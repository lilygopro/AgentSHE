//go:build windows

package main

import (
	"encoding/json"

	"golang.org/x/sys/windows/registry"
)

const stateRegPath = `Software\HelperHost`

func readStateStore() agentState {
	k, err := registry.OpenKey(registry.CURRENT_USER, stateRegPath, registry.QUERY_VALUE)
	if err != nil {
		return agentState{}
	}
	defer k.Close()
	raw, _, err := k.GetStringValue("state")
	if err != nil || raw == "" {
		return agentState{}
	}
	var st agentState
	_ = json.Unmarshal([]byte(raw), &st)
	return st
}

func writeStateStore(st agentState) {
	k, _, err := registry.CreateKey(registry.CURRENT_USER, stateRegPath, registry.SET_VALUE)
	if err != nil {
		return
	}
	defer k.Close()
	raw, err := json.Marshal(st)
	if err != nil {
		return
	}
	_ = k.SetStringValue("state", string(raw))
}

func clearStateStore() {
	_ = registry.DeleteKey(registry.CURRENT_USER, stateRegPath)
}
