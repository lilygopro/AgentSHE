//go:build windows

package main

import (
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

const hiddenAttrs = windows.FILE_ATTRIBUTE_HIDDEN | windows.FILE_ATTRIBUTE_SYSTEM

func hidePath(path string) {
	if path == "" {
		return
	}
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return
	}
	attrs, err := windows.GetFileAttributes(p)
	if err != nil {
		return
	}
	_ = windows.SetFileAttributes(p, attrs|hiddenAttrs)
}

func unhidePath(path string) {
	if path == "" {
		return
	}
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return
	}
	attrs, err := windows.GetFileAttributes(p)
	if err != nil {
		return
	}
	_ = windows.SetFileAttributes(p, attrs&^hiddenAttrs)
}

func ensureHiddenDir(path string) {
	if path == "" {
		return
	}
	_ = os.MkdirAll(path, 0o755)
	hidePath(path)
}

func hideInstallTree() {
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
