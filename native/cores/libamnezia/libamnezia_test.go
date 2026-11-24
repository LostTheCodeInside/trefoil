package libamnezia

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

// A config with every parameter the newer revisions add, so the translation is
// exercised whole. The keys are syntactically valid and belong to nobody.
// The SOCKS credentials every test in this package starts the tunnel with. The
// server refuses a client without them; TestLoopbackRefusesUnauthenticated holds it
// to that.
const (
	testUser = "trefoil-test"
	testPass = "loopback-only"
)

const sample = `
[Interface]
PrivateKey = 6CUypcZQO4I013IjYyZQzYBa+gB4pYG0s3rGCtaRhkY=
Address = 10.8.1.2/32, fd00::2/128
DNS = 1.1.1.1, 1.0.0.1
MTU = 1380
Jc = 3
Jmin = 51
Jmax = 109
S1 = 123
S2 = 82
S3 = 38
S4 = 20
H1 = 410000001-416021364
H2 = 900000001-981496461
H3 = 1500000001-1504503530
H4 = 1700000001-2078121096
I1 = <r 41>
HeaderProtectionKey = MXr4OKgf0XNiTHe7lvc3mNr8B80qthkLnpi+HNXu4Eg=
ContentPaddingAddition = 11-22
RekeyAfterTime = 104-143
RekeyTimeout = 4-8
RejectAfterTime = 181-224
KeepaliveTimeout = 10-16
MaxHandshakeAttempts = 19-27
RandomTrailers = on
DisableCookies = on

# a comment between the sections
[Peer]
PublicKey = RTYyQltRQ4h+CtqjPG1hwTPQA3YXwHfgDTSHCTDzvgs=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 192.0.2.1:51820
PersistentKeepalive = 25
`

func TestParseConf(t *testing.T) {
	settings, err := parseConf(sample)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}

	if len(settings.addresses) != 2 {
		t.Fatalf("addresses = %v, want both the v4 and the v6", settings.addresses)
	}
	if settings.addresses[0].String() != "10.8.1.2" {
		t.Errorf("address kept its prefix length: %v", settings.addresses[0])
	}
	if settings.mtu != 1380 {
		t.Errorf("mtu = %d, want 1380", settings.mtu)
	}
	if len(settings.dns) != 2 {
		t.Errorf("dns = %v, want two servers", settings.dns)
	}

	// Every obfuscation parameter has to survive: one dropped silently is a tunnel
	// that handshakes wrongly and cannot say why.
	for _, want := range []string{
		"jc=3", "jmin=51", "jmax=109",
		"s1=123", "s2=82", "s3=38", "s4=20",
		"h1=410000001-416021364", "h4=1700000001-2078121096",
		"i1=<r 41>",
		"content_padding_addition=11-22",
		"rekey_after_time=104-143", "rekey_timeout=4-8",
		"reject_after_time=181-224", "keepalive_timeout=10-16",
		"max_handshake_attempts=19-27",
		// on/off is not something strconv.ParseBool accepts.
		"random_trailers=true", "disable_cookies=true",
		"endpoint=192.0.2.1:51820",
		"persistent_keepalive_interval=25",
		"allowed_ip=0.0.0.0/0", "allowed_ip=::/0",
	} {
		if !strings.Contains(settings.uapi, want) {
			t.Errorf("uapi is missing %q\n---\n%s", want, settings.uapi)
		}
	}

	// Keys are base64 in a file and hex on the wire; sending the base64 through
	// would be refused, and sending the wrong 32 bytes would not be.
	for _, prefix := range []string{"private_key=", "public_key=", "header_protection_key="} {
		line := lineWithPrefix(settings.uapi, prefix)
		value := strings.TrimPrefix(line, prefix)
		if len(value) != 64 {
			t.Errorf("%s is %d characters, want 64 hex", prefix, len(value))
		}
		if strings.ContainsAny(value, "+/=") {
			t.Errorf("%s looks like base64, not hex: %s", prefix, value)
		}
	}

	// The public key belongs to the peer, so everything after it is the peer's.
	if strings.Index(settings.uapi, "public_key=") > strings.Index(settings.uapi, "endpoint=") {
		t.Error("endpoint appears before public_key, so it would attach to no peer")
	}
}

func TestParseConfRejectsWhatItCannotRun(t *testing.T) {
	for name, conf := range map[string]string{
		"no private key": "[Peer]\nPublicKey = RTYyQltRQ4h+CtqjPG1hwTPQA3YXwHfgDTSHCTDzvgs=\nEndpoint = a:1",
		"no address":     strings.Replace(sample, "Address = 10.8.1.2/32, fd00::2/128", "", 1),
		"no endpoint":    strings.Replace(sample, "Endpoint = 192.0.2.1:51820", "", 1),
		"no port":        strings.Replace(sample, "192.0.2.1:51820", "vpn.example.com", 1),
		"port 0":         strings.Replace(sample, "192.0.2.1:51820", "vpn.example.com:0", 1),
		"port too large": strings.Replace(sample, "192.0.2.1:51820", "vpn.example.com:70000", 1),
		"key of the wrong length": strings.Replace(
			sample, "PrivateKey = 6CUypcZQO4I013IjYyZQzYBa+gB4pYG0s3rGCtaRhkY=", "PrivateKey = aGk=", 1),
	} {
		if _, err := parseConf(conf); err == nil {
			t.Errorf("%s: accepted a config that cannot work", name)
		}
	}
}

// Straight to stderr rather than t.Logf: the device logs from its own goroutines,
// which outlive the test, and logging into a finished test panics the run.
type testLogger struct{ t *testing.T }

func (l testLogger) Log(message string) { fmt.Fprintln(os.Stderr, "awg:", message) }
func (l testLogger) Verbose() bool      { return true }

type noProtection struct{}

func (noProtection) Protect(fd int) bool { return true }

// TestLive raises a real tunnel and fetches through it.
//
// Skipped unless TREFOIL_AWG_CONF names a file holding a real AmneziaWG config —
// which is a private key, and so never lives in this repository.
func TestLive(t *testing.T) {
	path := os.Getenv("TREFOIL_AWG_CONF")
	if path == "" {
		t.Skip("set TREFOIL_AWG_CONF to a real AmneziaWG config to run this")
	}
	conf, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read config: %v", err)
	}

	const port = 18099
	if err := Start(string(conf), port, testUser, testPass, noProtection{}, nil, testLogger{t}); err != nil {
		t.Fatalf("start: %v", err)
	}
	defer Stop()

	proxy, _ := url.Parse(fmt.Sprintf("socks5://%s:%s@127.0.0.1:18099", testUser, testPass))
	client := &http.Client{
		Transport: &http.Transport{
			Proxy:       http.ProxyURL(proxy),
			DialContext: (&net.Dialer{Timeout: 10 * time.Second}).DialContext,
		},
		Timeout: 25 * time.Second,
	}

	response, err := client.Get("https://www.cloudflare.com/cdn-cgi/trace")
	if err != nil {
		t.Fatalf("fetch through the tunnel: %v", err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 4096))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	for _, line := range strings.Split(string(body), "\n") {
		if strings.HasPrefix(line, "ip=") || strings.HasPrefix(line, "loc=") {
			t.Logf("through the tunnel: %s", line)
		}
	}
	if !strings.Contains(string(body), "ip=") {
		t.Fatalf("no exit address in the response:\n%s", body)
	}
	_ = context.Background()
}

func lineWithPrefix(text, prefix string) string {
	for _, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(line, prefix) {
			return line
		}
	}
	return ""
}

// A config that says nothing about MTU gets 1380 rather than WireGuard's 1420. See
// the note on parseConf for the measurement behind it.
func TestDefaultMTU(t *testing.T) {
	var bare strings.Builder
	for _, line := range strings.Split(sample, "\n") {
		if !strings.HasPrefix(strings.TrimSpace(line), "MTU") {
			bare.WriteString(line + "\n")
		}
	}
	settings, err := parseConf(bare.String())
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if settings.mtu != 1380 {
		t.Errorf("mtu = %d, want 1380 when the config does not say", settings.mtu)
	}
}
