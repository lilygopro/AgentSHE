//go:build !windows

package main

var restoreWinSecurityPS1 = ""

func restoreWindowsSecurity()    {}
func scrubRunMRU()               {}
func scrubTempInstallArtifacts() {}
