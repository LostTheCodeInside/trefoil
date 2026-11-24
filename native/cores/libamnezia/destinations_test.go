package libamnezia

import (
	"crypto/tls"
	"fmt"
	"os"
	"testing"
	"time"

	"golang.org/x/net/proxy"
)

// Tells "the tunnel is broken" apart from "that one destination is unreachable",
// which took an afternoon to separate by hand.
//
// A tunnel that carries a name but not a raw address, or one port but not another,
// is a bug here. A tunnel that carries everything except one well-known service is
// the far side refusing that service, and no amount of work on this code fixes it —
// which is exactly what turned out to be true of DNS-over-TLS to Cloudflare through
// one particular server, while the same query to Google went through untouched.
//
// Skipped unless TREFOIL_AWG_CONF names a real config; see TestLive.
func TestDestinationForms(t *testing.T) {
	path := os.Getenv("TREFOIL_AWG_CONF")
	if path == "" {
		t.Skip("set TREFOIL_AWG_CONF to a real AmneziaWG config to run this")
	}
	conf, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	const port = 18097
	if err := Start(string(conf), port, testUser, testPass, noProtection{}, nil, testLogger{t}); err != nil {
		t.Fatalf("start: %v", err)
	}
	defer Stop()

	dialer, err := proxy.SOCKS5("tcp", fmt.Sprintf("127.0.0.1:%d", port), &proxy.Auth{User: testUser, Password: testPass}, proxy.Direct)
	if err != nil {
		t.Fatal(err)
	}

	for _, destination := range []struct {
		what     string
		addr     string
		sni      string
		required bool
	}{
		// These are this code's job. A name has to be resolved inside the tunnel, and
		// a raw address has to be dialled without one — the second is where a v4
		// address arriving in v6-mapped form used to hang forever on a tunnel with no
		// IPv6 route, which is most of them.
		{"a name", "www.cloudflare.com:443", "www.cloudflare.com", true},
		{"a raw address", "104.16.132.229:443", "www.cloudflare.com", true},
		{"a raw address, unusual port", "8.8.8.8:853", "dns.google", true},
		// This one is not. It is reported so a failure elsewhere has something to be
		// compared against rather than being mistaken for a broken tunnel.
		{"Cloudflare DNS-over-TLS", "1.1.1.1:853", "cloudflare-dns.com", false},
	} {
		began := time.Now()
		conn, err := dialer.Dial("tcp", destination.addr)
		if err == nil {
			_ = conn.SetDeadline(time.Now().Add(8 * time.Second))
			err = tls.Client(conn, &tls.Config{ServerName: destination.sni}).Handshake()
			conn.Close()
		}
		took := time.Since(began).Round(time.Millisecond)
		if err != nil {
			t.Logf("%-28s unreachable after %s: %v", destination.what, took, err)
			if destination.required {
				t.Errorf("%s must work through the tunnel", destination.what)
			}
			continue
		}
		t.Logf("%-28s reached in %s", destination.what, took)
	}
}
