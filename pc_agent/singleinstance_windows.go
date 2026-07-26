//go:build windows

package main

import (
	"os"
	"syscall"
	"unsafe"
)

var (
	modKernel32          = syscall.NewLazyDLL("kernel32.dll")
	procCreateMutexW     = modKernel32.NewProc("CreateMutexW")
	procGetLastError     = modKernel32.NewProc("GetLastError")
	procOpenProcess      = modKernel32.NewProc("OpenProcess")
	procCloseHandle      = modKernel32.NewProc("CloseHandle")
	helperInstanceMutex  uintptr
)

const (
	errorAlreadyExists           = 183
	processQueryLimitedInformation = 0x1000
)

func acquireSingleInstance() {
	name, err := syscall.UTF16PtrFromString("Local\\HelperHostSingleInstance")
	if err != nil {
		return
	}
	r1, _, _ := procCreateMutexW.Call(0, 1, uintptr(unsafe.Pointer(name)))
	helperInstanceMutex = r1
	last, _, _ := procGetLastError.Call()
	if last == errorAlreadyExists {
		os.Exit(0)
	}
}

func processAliveWindows(pid int) bool {
	if pid <= 0 {
		return false
	}
	h, _, _ := procOpenProcess.Call(uintptr(processQueryLimitedInformation), 0, uintptr(pid))
	if h == 0 {
		return false
	}
	procCloseHandle.Call(h)
	return true
}
