// Package libkdf derives the key a backup is encrypted with.
//
// Android ships no memory-hard key derivation, and what it does ship (PBKDF2) is
// cheap to run in parallel on a graphics card. Go's Argon2id is already among what
// the cores depend on, so this costs the binding one small package rather than the
// app another library.
package libkdf

import (
	"errors"

	"golang.org/x/crypto/argon2"
)

// The most a caller may ask for. A backup is a file from anywhere, and a derivation
// sized by its contents could otherwise be used to run a phone out of memory.
const (
	maxMemoryKiB = 256 * 1024
	maxPasses    = 16
	maxThreads   = 16
	minSaltBytes = 16
	maxKeyBytes  = 64
)

// Argon2id returns keyBytes of key material for the password.
//
// The limits are errors rather than panics: a Go panic cannot be caught from Kotlin
// and takes the whole process, VPN included, down with it.
func Argon2id(password, salt []byte, passes, memoryKiB, threads, keyBytes int) ([]byte, error) {
	switch {
	case len(salt) < minSaltBytes:
		return nil, errors.New("the salt is too short")
	case passes < 1 || passes > maxPasses:
		return nil, errors.New("passes out of range")
	case threads < 1 || threads > maxThreads:
		return nil, errors.New("threads out of range")
	case memoryKiB < 8*threads || memoryKiB > maxMemoryKiB:
		return nil, errors.New("memory out of range")
	case keyBytes < 16 || keyBytes > maxKeyBytes:
		return nil, errors.New("key length out of range")
	}
	return argon2.IDKey(password, salt, uint32(passes), uint32(memoryKiB), uint8(threads), uint32(keyBytes)), nil
}
