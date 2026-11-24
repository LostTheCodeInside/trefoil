package libamnezia

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"strconv"
	"sync"
	"testing"
	"time"

	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/protocol/socks"
)

// How fast the tunnel can carry data on this machine, with no network in the way.
//
// Both ends run in this process over loopback: the client exactly as the app runs it
// (SOCKS in front, the userspace stack, the device), and a peer with its own stack
// serving and swallowing data. The peer's work competes for the same CPU, so the
// figures are a floor rather than what a phone gets from a real server — but they
// are a fair comparison between two builds, which is what this is for. Cross-compile
// it and run it on the phone itself:
//
//	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go test -c -o amnezia.test ./libamnezia
//	adb push amnezia.test /data/local/tmp/ && adb shell \
//	  'cd /data/local/tmp && TREFOIL_BENCH=1 ./amnezia.test -test.run Throughput -test.v'
//
// TREFOIL_BENCH_MB sets how much each stream carries (default 200).
func TestThroughputOverLoopback(t *testing.T) {
	if os.Getenv("TREFOIL_BENCH") == "" {
		t.Skip("set TREFOIL_BENCH=1 to measure throughput")
	}
	megabytes := 200
	if v, err := strconv.Atoi(os.Getenv("TREFOIL_BENCH_MB")); err == nil && v > 0 {
		megabytes = v
	}
	total := int64(megabytes) << 20

	const (
		clientAddr = "10.9.0.1"
		serverAddr = "10.9.0.2"
		dataPort   = 9000
		socksPort  = 18097
	)
	client, server := newKeypair(t), newKeypair(t)
	peerNet, endpoint := startPeer(t, peerConfig{
		privateHex:  server.hex,
		peerPubHex:  client.pubHex,
		address:     serverAddr,
		peerAllowed: clientAddr,
	})

	// A source and a sink inside the peer's own stack. The first byte a client sends
	// says which: 'd' asks for total bytes, 'u' sends total bytes and waits for one
	// back, so the clock stops only once the peer has everything.
	listener, err := peerNet.ListenTCPAddrPort(netip.AddrPortFrom(netip.MustParseAddr(serverAddr), dataPort))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	go func() {
		chunk := make([]byte, 64<<10)
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				command := make([]byte, 1)
				if _, err := io.ReadFull(conn, command); err != nil {
					return
				}
				switch command[0] {
				case 'd':
					for sent := int64(0); sent < total; {
						n, err := conn.Write(chunk[:min(int64(len(chunk)), total-sent)])
						if err != nil {
							return
						}
						sent += int64(n)
					}
				case 'u':
					if _, err := io.CopyN(io.Discard, conn, total); err != nil {
						return
					}
					_, _ = conn.Write([]byte{1})
				}
			}(conn)
		}
	}()

	conf := fmt.Sprintf(
		"[Interface]\nPrivateKey = %s\nAddress = %s/32\nMTU = 1380\n"+
			"[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\nEndpoint = 127.0.0.1:%d\n",
		client.b64, clientAddr, server.pubB64, serverAddr, endpoint,
	)
	if err := Start(conf, socksPort, testUser, testPass, noProtection{}, nil, quietLogger{}); err != nil {
		t.Fatalf("start: %v", err)
	}
	defer Stop()

	proxy := socks.NewClient(N.SystemDialer, M.ParseSocksaddr(fmt.Sprintf("127.0.0.1:%d", socksPort)),
		socks.Version5, testUser, testPass)
	destination := M.ParseSocksaddr(fmt.Sprintf("%s:%d", serverAddr, dataPort))

	stream := func(command byte) (time.Duration, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancel()
		conn, err := proxy.DialContext(ctx, "tcp", destination)
		if err != nil {
			return 0, err
		}
		defer conn.Close()
		started := time.Now()
		if _, err := conn.Write([]byte{command}); err != nil {
			return 0, err
		}
		switch command {
		case 'd':
			if _, err := io.CopyN(io.Discard, conn, total); err != nil {
				return 0, err
			}
		case 'u':
			chunk := make([]byte, 64<<10)
			for sent := int64(0); sent < total; {
				n, err := conn.Write(chunk[:min(int64(len(chunk)), total-sent)])
				if err != nil {
					return 0, err
				}
				sent += int64(n)
			}
			if _, err := io.ReadFull(conn, make([]byte, 1)); err != nil {
				return 0, err
			}
		}
		return time.Since(started), nil
	}
	mbps := func(bytes int64, elapsed time.Duration) float64 {
		return float64(bytes) * 8 / elapsed.Seconds() / 1e6
	}

	// One stream first, untimed, so the handshake and the window ramp are not
	// counted against the first measurement.
	if _, err := stream('d'); err != nil {
		t.Fatalf("warm-up: %v", err)
	}
	for _, direction := range []struct {
		name    string
		command byte
	}{{"download", 'd'}, {"upload", 'u'}} {
		elapsed, err := stream(direction.command)
		if err != nil {
			t.Fatalf("%s: %v", direction.name, err)
		}
		t.Logf("%-8s 1 stream:  %7.0f Mbit/s", direction.name, mbps(total, elapsed))
	}

	const parallel = 4
	var wg sync.WaitGroup
	errs := make(chan error, parallel)
	started := time.Now()
	for range parallel {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := stream('d'); err != nil {
				errs <- err
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatalf("parallel download: %v", err)
	}
	t.Logf("download %d streams: %7.0f Mbit/s", parallel, mbps(total*parallel, time.Since(started)))
}

// The same for UDP, which is what QUIC — YouTube, most of Google, many speed tests —
// actually sends. Datagrams cross SOCKS UDP ASSOCIATE into the stack, so this path
// has none of TCP's batching and pays its costs per packet.
//
// Measured as echoes with a fixed number in flight rather than a blind blast: with
// no congestion control, blasting only measures how much the queues drop.
func TestUDPThroughputOverLoopback(t *testing.T) {
	if os.Getenv("TREFOIL_BENCH") == "" {
		t.Skip("set TREFOIL_BENCH=1 to measure throughput")
	}
	const (
		clientAddr = "10.9.0.1"
		serverAddr = "10.9.0.2"
		echoPort   = 5353
		socksPort  = 18098
		size       = 1200
		inFlight   = 128
		duration   = 5 * time.Second
	)
	client, server := newKeypair(t), newKeypair(t)
	peerNet, endpoint := startPeer(t, peerConfig{
		privateHex:  server.hex,
		peerPubHex:  client.pubHex,
		address:     serverAddr,
		peerAllowed: clientAddr,
	})
	echoUDP(t, peerNet, netip.AddrPortFrom(netip.MustParseAddr(serverAddr), echoPort))

	conf := fmt.Sprintf(
		"[Interface]\nPrivateKey = %s\nAddress = %s/32\nMTU = 1380\n"+
			"[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\nEndpoint = 127.0.0.1:%d\n",
		client.b64, clientAddr, server.pubB64, serverAddr, endpoint,
	)
	if err := Start(conf, socksPort, testUser, testPass, noProtection{}, nil, quietLogger{}); err != nil {
		t.Fatalf("start: %v", err)
	}
	defer Stop()

	proxy := socks.NewClient(N.SystemDialer, M.ParseSocksaddr(fmt.Sprintf("127.0.0.1:%d", socksPort)),
		socks.Version5, testUser, testPass)
	destination := M.ParseSocksaddr(fmt.Sprintf("%s:%d", serverAddr, echoPort))
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	packets, err := proxy.ListenPacket(ctx, destination)
	if err != nil {
		t.Fatalf("udp associate: %v", err)
	}
	defer packets.Close()

	payload := make([]byte, size)
	send := func() error {
		_, err := packets.WriteTo(payload, destination.UDPAddr())
		return err
	}
	// Prime the window, then send one more for every echo that returns.
	for range inFlight {
		if err := send(); err != nil {
			t.Fatal(err)
		}
	}
	received := 0
	answer := make([]byte, 2048)
	deadline := time.Now().Add(duration)
	started := time.Now()
	for time.Now().Before(deadline) {
		_ = packets.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
		if _, _, err := packets.ReadFrom(answer); err != nil {
			// A lost datagram shrinks the window; put one back.
			_ = send()
			continue
		}
		received++
		_ = send()
	}
	elapsed := time.Since(started)
	t.Logf("udp echo, %d in flight: %7.0f Mbit/s each way (%d datagrams of %d bytes)",
		inFlight, float64(received*size)*8/elapsed.Seconds()/1e6, received, size)
}
