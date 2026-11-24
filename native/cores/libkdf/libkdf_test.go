package libkdf

import (
	"encoding/hex"
	"testing"
)

// A fixed answer, from the reference implementation rather than from this one, so that
// a change of library or of argument order cannot quietly make every backup written
// so far unreadable.
func TestArgon2idMatchesTheReference(t *testing.T) {
	key, err := Argon2id([]byte("password"), []byte("somesaltsomesalt"), 3, 1024, 4, 32)
	if err != nil {
		t.Fatal(err)
	}
	const want = "d488a244d764d18a6db69e08a29c66824d78ddfacf324c13239e35dce7517eea"
	if got := hex.EncodeToString(key); got != want {
		t.Fatalf("derived %s, want %s", got, want)
	}
}

func TestArgon2idRefusesWhatItWillNotRun(t *testing.T) {
	salt := []byte("somesaltsomesalt")
	for name, try := range map[string]func() ([]byte, error){
		"short salt":     func() ([]byte, error) { return Argon2id(nil, salt[:8], 3, 1024, 4, 32) },
		"no passes":      func() ([]byte, error) { return Argon2id(nil, salt, 0, 1024, 4, 32) },
		"no threads":     func() ([]byte, error) { return Argon2id(nil, salt, 3, 1024, 0, 32) },
		"too little":     func() ([]byte, error) { return Argon2id(nil, salt, 3, 16, 4, 32) },
		"too much":       func() ([]byte, error) { return Argon2id(nil, salt, 3, 1<<30, 4, 32) },
		"no key":         func() ([]byte, error) { return Argon2id(nil, salt, 3, 1024, 4, 0) },
		"negative sizes": func() ([]byte, error) { return Argon2id(nil, salt, -1, -1, -1, -1) },
	} {
		if _, err := try(); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
