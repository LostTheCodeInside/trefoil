package libamnezia

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// Whether several connections at once share the tunnel, or one of them takes it.
//
// This is a different question from TestThroughput, and the reason it has its own
// test: a tunnel can carry 99 Mbps down a single stream and still be unusable,
// because a page load is dozens of connections and a speed test is several. That was
// the actual bug — one stream ran at 12 MB/s while the others sat at 190 B/s, which
// is a stalled connection with extra steps.
//
// It fails loudly on the old code rather than reporting a poor ratio: a starved
// stream needs eleven hours for its share and hits the deadline instead.
//
//	TREFOIL_AWG_CONF=/path/to.conf go test ./libamnezia/ -run TestConcurrentStreamsShare -v -count=1
func TestConcurrentStreamsShare(t *testing.T) {
	path := os.Getenv("TREFOIL_AWG_CONF")
	if path == "" {
		t.Skip("set TREFOIL_AWG_CONF")
	}
	conf, _ := os.ReadFile(path)
	const port = 18095
	if err := Start(string(conf), port, testUser, testPass, noProtection{}, nil, testLogger{t}); err != nil {
		t.Fatal(err)
	}
	defer Stop()

	const (
		streams  = 4
		perMB    = 8
		deadline = 90 * time.Second
	)
	source := os.Getenv("TREFOIL_SPEED_URL")
	if source == "" {
		source = "https://speed.cloudflare.com/__down?bytes=%d"
	}
	if strings.Contains(source, "%d") {
		source = fmt.Sprintf(source, perMB*1024*1024)
	}

	proxy, _ := url.Parse(fmt.Sprintf("socks5://%s:%s@127.0.0.1:%d", testUser, testPass, port))
	// One transport, so the streams contend the way a browser's would rather than
	// each getting a private everything.
	client := &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(proxy)}}

	ctx, cancel := context.WithTimeout(context.Background(), deadline)
	defer cancel()

	type result struct {
		bytes int64
		rate  float64
		err   error
	}
	results := make([]result, streams)
	var wait sync.WaitGroup
	began := time.Now()
	for i := range streams {
		wait.Add(1)
		go func() {
			defer wait.Done()
			start := time.Now()
			req, _ := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
			resp, err := client.Do(req)
			if err != nil {
				results[i] = result{err: err}
				return
			}
			defer resp.Body.Close()
			n, err := io.Copy(io.Discard, resp.Body)
			results[i] = result{bytes: n, rate: float64(n) / time.Since(start).Seconds(), err: err}
		}()
	}
	wait.Wait()
	elapsed := time.Since(began)

	var slowest, fastest float64
	for i, r := range results {
		if r.err != nil {
			// Printed before the failure, because which stream died and how far it
			// got is the whole diagnosis.
			fmt.Fprintf(os.Stderr, "  stream %d: %d bytes, %v\n", i, r.bytes, r.err)
			continue
		}
		fmt.Fprintf(os.Stderr, "  stream %d: %.2f MB/s (%d bytes)\n", i, r.rate/1e6, r.bytes)
		if r.rate > fastest {
			fastest = r.rate
		}
		if slowest == 0 || r.rate < slowest {
			slowest = r.rate
		}
	}
	fmt.Fprintf(os.Stderr, "  all %d in %s\n", streams, elapsed.Round(time.Millisecond))

	for i, r := range results {
		if r.err != nil {
			t.Fatalf("stream %d did not finish: %v — the others took the tunnel", i, r.err)
		}
		if r.bytes < perMB*1024*1024/2 {
			t.Skipf("stream %d got only %d bytes; the endpoint is not serving the test", i, r.bytes)
		}
	}
	// Generous. An even split is 1x and scheduling noise makes a few times normal;
	// the failure this guards against was five orders of magnitude.
	if ratio := fastest / slowest; ratio > 20 {
		t.Errorf("fastest stream is %.0fx the slowest (%.2f vs %.6f MB/s): one is starving the rest",
			ratio, fastest/1e6, slowest/1e6)
	}
}
