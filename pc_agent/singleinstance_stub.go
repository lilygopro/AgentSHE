//go:build !windows

package main

func acquireSingleInstance() {}

func processAliveWindows(pid int) bool { return false }
