package libamnezia

import (
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

// How much this carries, so a claim about speed can be a number.
//
// Run it against a real config and it will say. Note what it cannot say: this
// machine sits close to the server, so the receive window is never the thing in the
// way here, and a change that matters only at a real round trip will look like noise.
// A phone is the only place some of these differences show up.
//
//	TREFOIL_AWG_CONF=/path/to.conf go test ./libamnezia/ -run TestThroughput -v -count=1
//
// -count=1 is not optional: without it the second run reports the first run's number.
func TestThroughput(t *testing.T) {
	path := os.Getenv("TREFOIL_AWG_CONF")
	if path == "" {
		t.Skip("set TREFOIL_AWG_CONF")
	}
	conf, _ := os.ReadFile(path)
	const port = 18094
	if err := Start(string(conf), port, testUser, testPass, noProtection{}, testLogger{t}); err != nil {
		t.Fatal(err)
	}
	defer Stop()

	proxy, _ := url.Parse(fmt.Sprintf("socks5://%s:%s@127.0.0.1:%d", testUser, testPass, port))
	client := &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(proxy)}}
	// The same fetch with the SOCKS server taken out of the path. When the two
	// disagree the relay is the problem; when they agree it is the tunnel, and that
	// is a question worth being able to answer without rebuilding anything.
	direct := &http.Client{Transport: &http.Transport{DialContext: DialContext}}

	for _, path := range []struct {
		name string
		by   *http.Client
	}{{"socks", client}, {"tunnel", direct}} {
		for _, mb := range []int{10, 25} {
			began := time.Now()
			// Overridable, because a public speed endpoint will eventually answer 429 to
			// somebody measuring the same thing twenty times in an afternoon — and a
			// rate-limited reply is a small body that divides into a very believable
			// zero. Hence the size check below: a wrong number is worse than none.
			source := os.Getenv("TREFOIL_SPEED_URL")
			if source == "" {
				source = "https://speed.cloudflare.com/__down?bytes=%d"
			}
			if strings.Contains(source, "%d") {
				source = fmt.Sprintf(source, mb*1024*1024)
			}
			resp, err := path.by.Get(source)
			if err != nil {
				t.Fatalf("%s %d MB: %v", path.name, mb, err)
			}
			n, copyErr := io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			if n < int64(mb)*1024*1024/2 {
				fmt.Fprintf(os.Stderr, "  %-6s %2d MB: only %d bytes — status %s, err %v\n", path.name, mb, n, resp.Status, copyErr)
				continue
			}
			elapsed := time.Since(began)
			mbps := float64(n) * 8 / elapsed.Seconds() / 1e6
			fmt.Fprintf(os.Stderr, "  %-6s %2d MB: %6.2f Mbps  (%s)\n", path.name, mb, mbps, elapsed.Round(time.Millisecond))
			// The stack's own counters alongside the rate, because "slow" and "losing
			// packets" look identical from the outside and are not the same problem.
			fmt.Fprintf(os.Stderr, "        %s\n", Stats())
		}
	}
}
