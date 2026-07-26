//go:build !windows

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

func hidePath(path string) {
	if path == "" || runtime.GOOS != "darwin" {
		return
	}
	_ = exec.Command("chflags", "hidden", path).Run()
}

func unhidePath(path string) {
	if path == "" || runtime.GOOS != "darwin" {
		return
	}
	_ = exec.Command("chflags", "nohidden", path).Run()
}

func hideInstallTree() {
	if runtime.GOOS != "darwin" {
		return
	}
	hidePath(dir)
	hidePath(cacheDir)
	_ = filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err == nil {
			hidePath(p)
		}
		return nil
	})
	_ = filepath.Walk(cacheDir, func(p string, info os.FileInfo, err error) error {
		if err == nil {
			hidePath(p)
		}
		return nil
	})
}

func ensureHiddenDir(path string) {
	if path == "" {
		return
	}
	_ = os.MkdirAll(path, 0o755)
	hidePath(path)
}
