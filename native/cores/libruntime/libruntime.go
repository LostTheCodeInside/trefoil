// Package libruntime holds the Go runtime settings the app changes while running.
//
// All three cores live in one binding and so share one Go runtime: a setting made
// here applies to sing-box, Xray and AmneziaWG alike.
package libruntime

import "runtime/debug"

// SetLowMemory trades throughput for a smaller heap by collecting garbage far more
// often.
//
// It is what libbox.SetMemoryLimit did on Android until sing-box 1.14 removed it in
// favour of an OOM killer that can only be configured once, at setup, and is aimed at
// iOS's hard memory ceiling. Kept here so the app's switch still applies the moment it
// is flipped, with the same effect it always had.
func SetLowMemory(enabled bool) {
	if enabled {
		debug.SetGCPercent(10)
	} else {
		debug.SetGCPercent(100)
	}
}
