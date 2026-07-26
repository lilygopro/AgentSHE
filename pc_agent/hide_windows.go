//go:build windows

package main

import (
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

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
	_ = windows.SetFileAttributes(p, attrs|windows.FILE_ATTRIBUTE_HIDDEN)
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
	_ = windows.SetFileAttributes(p, attrs&^windows.FILE_ATTRIBUTE_HIDDEN)
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
