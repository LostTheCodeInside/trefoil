// Package tools pins dependencies that no runtime code in this module imports.
//
// Two reasons they must be here:
//   - gobind resolves its own runtime support package out of the target module's
//     dependency graph, so binding fails unless gomobile is required.
//   - libbox is bound directly by import path rather than wrapped, so nothing in
//     this module imports it and `go mod tidy` would otherwise drop sing-box.
//
// Nothing imports this package, so it adds nothing to the .aar.
package tools

import (
	_ "github.com/sagernet/gomobile/bind"
	_ "github.com/sagernet/sing-box/experimental/libbox"
)
