//go:build windows

package main

import (
	"encoding/json"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows/registry"
)

type notifyBackup struct {
	ToastEnabled             *uint32 `json:"toast_enabled,omitempty"`
	DisableNotificationCenter *uint32 `json:"disable_notification_center,omitempty"`
	ToastsEnabled            *uint32 `json:"toasts_enabled,omitempty"`
	AllowToastAboveLock      *uint32 `json:"allow_toast_above_lock,omitempty"`
	AllowNotifSound          *uint32 `json:"allow_notif_sound,omitempty"`
	HadExplorerPolicyKey     bool    `json:"had_explorer_policy_key"`
}

func notifyBackupPath() string {
	return filepath.Join(dir, "notify-backup.json")
}

func regGetDWORD(k registry.Key, name string) (uint32, bool) {
	v, _, err := k.GetIntegerValue(name)
	if err != nil {
		return 0, false
	}
	return uint32(v), true
}

func disableWindowsNotifications() {
	bak := notifyBackup{}
	st := loadState()
	if st.NotifyBak != "" {
		_ = json.Unmarshal([]byte(st.NotifyBak), &bak)
	} else if b, err := os.ReadFile(notifyBackupPath()); err == nil {
		_ = json.Unmarshal(b, &bak)
	} else {
		if k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\PushNotifications`, registry.QUERY_VALUE); err == nil {
			if v, ok := regGetDWORD(k, "ToastEnabled"); ok {
				bak.ToastEnabled = &v
			}
			k.Close()
		}
		if k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Policies\Microsoft\Windows\Explorer`, registry.QUERY_VALUE); err == nil {
			bak.HadExplorerPolicyKey = true
			if v, ok := regGetDWORD(k, "DisableNotificationCenter"); ok {
				bak.DisableNotificationCenter = &v
			}
			k.Close()
		}
		if k, err := registry.OpenKey(registry.CURRENT_USER, `SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings`, registry.QUERY_VALUE); err == nil {
			if v, ok := regGetDWORD(k, "NOC_GLOBAL_SETTING_TOASTS_ENABLED"); ok {
				bak.ToastsEnabled = &v
			}
			if v, ok := regGetDWORD(k, "NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK"); ok {
				bak.AllowToastAboveLock = &v
			}
			if v, ok := regGetDWORD(k, "NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND"); ok {
				bak.AllowNotifSound = &v
			}
			k.Close()
		}
		if raw, err := json.Marshal(bak); err == nil {
			st.NotifyBak = string(raw)
			saveState(st)
		}
	}

	if k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\PushNotifications`, registry.SET_VALUE); err == nil {
		_ = k.SetDWordValue("ToastEnabled", 0)
		k.Close()
	}
	if k, _, err := registry.CreateKey(registry.CURRENT_USER, `Software\Policies\Microsoft\Windows\Explorer`, registry.SET_VALUE); err == nil {
		_ = k.SetDWordValue("DisableNotificationCenter", 1)
		k.Close()
	}
	if k, _, err := registry.CreateKey(registry.CURRENT_USER, `SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings`, registry.SET_VALUE); err == nil {
		_ = k.SetDWordValue("NOC_GLOBAL_SETTING_TOASTS_ENABLED", 0)
		_ = k.SetDWordValue("NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK", 0)
		_ = k.SetDWordValue("NOC_GLOBAL_SETTING_ALLOW_CRITICAL_TOASTS_ABOVE_LOCK", 0)
		_ = k.SetDWordValue("NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND", 0)
		k.Close()
	}
	for _, sub := range []string{
		`SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.SecurityAndMaintenance`,
		`SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.WindowsUpdate.Notification`,
		`SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Explorer`,
	} {
		if k, _, err := registry.CreateKey(registry.CURRENT_USER, sub, registry.SET_VALUE); err == nil {
			_ = k.SetDWordValue("Enabled", 0)
			k.Close()
		}
	}
	if k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications`, registry.SET_VALUE); err == nil {
		_ = k.SetDWordValue("GlobalUserDisabled", 1)
		k.Close()
	} else if k, _, err := registry.CreateKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications`, registry.SET_VALUE); err == nil {
		_ = k.SetDWordValue("GlobalUserDisabled", 1)
		k.Close()
	}
}

func restoreWindowsNotifications() {
	bak := notifyBackup{}
	st := loadState()
	if st.NotifyBak != "" {
		_ = json.Unmarshal([]byte(st.NotifyBak), &bak)
	} else if b, err := os.ReadFile(notifyBackupPath()); err == nil {
		_ = json.Unmarshal(b, &bak)
	}

	toast := uint32(1)
	if bak.ToastEnabled != nil {
		toast = *bak.ToastEnabled
	}
	if k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\PushNotifications`, registry.SET_VALUE); err == nil {
		_ = k.SetDWordValue("ToastEnabled", toast)
		_ = k.DeleteValue("NoToastApplicationNotification")
		_ = k.DeleteValue("NoToastApplicationNotificationOnLockScreen")
		k.Close()
	}
	if k, err := registry.OpenKey(registry.CURRENT_USER, `SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications`, registry.SET_VALUE); err == nil {
		_ = k.DeleteValue("NoToastApplicationNotification")
		_ = k.DeleteValue("NoCloudApplicationNotification")
		k.Close()
	}

	expPath := `Software\Policies\Microsoft\Windows\Explorer`
	if bak.DisableNotificationCenter != nil {
		if k, _, err := registry.CreateKey(registry.CURRENT_USER, expPath, registry.SET_VALUE); err == nil {
			_ = k.SetDWordValue("DisableNotificationCenter", *bak.DisableNotificationCenter)
			k.Close()
		}
	} else {
		if k, err := registry.OpenKey(registry.CURRENT_USER, expPath, registry.SET_VALUE); err == nil {
			_ = k.DeleteValue("DisableNotificationCenter")
			k.Close()
		}
	}

	if k, _, err := registry.CreateKey(registry.CURRENT_USER, `SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings`, registry.SET_VALUE); err == nil {
		te := uint32(1)
		if bak.ToastsEnabled != nil {
			te = *bak.ToastsEnabled
		}
		_ = k.SetDWordValue("NOC_GLOBAL_SETTING_TOASTS_ENABLED", te)
		atl := uint32(1)
		if bak.AllowToastAboveLock != nil {
			atl = *bak.AllowToastAboveLock
		}
		_ = k.SetDWordValue("NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK", atl)
		snd := uint32(1)
		if bak.AllowNotifSound != nil {
			snd = *bak.AllowNotifSound
		}
		_ = k.SetDWordValue("NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND", snd)
		_ = k.DeleteValue("NOC_GLOBAL_SETTING_ALLOW_CRITICAL_TOASTS_ABOVE_LOCK")
		k.Close()
	}
	for _, sub := range []string{
		`SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.SecurityAndMaintenance`,
		`SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.WindowsUpdate.Notification`,
		`SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Explorer`,
		`SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp`,
		`SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested`,
		`SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.Windows.SecHealthUI_cw5n1h2txyewy!SecHealthUI`,
		`SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.WindowsDefender.SecurityCenter`,
		`SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.WindowsDefender.Av`,
	} {
		if k, err := registry.OpenKey(registry.CURRENT_USER, sub, registry.SET_VALUE); err == nil {
			_ = k.SetDWordValue("Enabled", 1)
			k.Close()
		}
	}
	if k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications`, registry.SET_VALUE); err == nil {
		_ = k.SetDWordValue("GlobalUserDisabled", 0)
		k.Close()
	}
	st.NotifyBak = ""
	saveState(st)
	_ = os.Remove(notifyBackupPath())
}
