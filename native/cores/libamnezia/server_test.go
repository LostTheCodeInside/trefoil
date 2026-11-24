package libamnezia

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"

	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/protocol/socks"
)

// startAgainstPeer raises a tunnel to a peer in this process, reached by the endpoint
// given (%d is the peer's port), and returns where its echo server is.
func startAgainstPeer(t *testing.T, socksPort int, endpoint string, resolver Resolver) M.Socksaddr {
	t.Helper()
	const clientAddr, serverAddr, echoPort = "10.9.0.1", "10.9.0.2", 5353
	client, server := newKeypair(t), newKeypair(t)
	peerNet, port := startPeer(t, peerConfig{
		privateHex: server.hex, peerPubHex: client.pubHex,
		address: serverAddr, peerAllowed: clientAddr,
	})
	echoTCP(t, peerNet, netip.AddrPortFrom(netip.MustParseAddr(serverAddr), echoPort))
	conf := fmt.Sprintf(
		"[Interface]\nPrivateKey = %s\nAddress = %s/32\n"+
			"[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\nEndpoint = %s\n",
		client.b64, clientAddr, server.pubB64, serverAddr, fmt.Sprintf(endpoint, port),
	)
	if err := Start(conf, socksPort, testUser, testPass, noProtection{}, resolver, quietLogger{}); err != nil {
		t.Fatalf("start: %v", err)
	}
	t.Cleanup(Stop)
	return M.ParseSocksaddr(fmt.Sprintf("%s:%d", serverAddr, echoPort))
}

func echoThrough(t *testing.T, socksPort int, destination M.Socksaddr) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	proxy := socks.NewClient(N.SystemDialer,
		M.ParseSocksaddr(fmt.Sprintf("127.0.0.1:%d", socksPort)), socks.Version5, testUser, testPass)
	stream, err := proxy.DialContext(ctx, "tcp", destination)
	if err != nil {
		t.Fatalf("connect through the tunnel: %v", err)
	}
	defer stream.Close()
	_ = stream.SetDeadline(time.Now().Add(20 * time.Second))
	if _, err := stream.Write([]byte("hello")); err != nil {
		t.Fatalf("write: %v", err)
	}
	back := make([]byte, 5)
	if _, err := io.ReadFull(stream, back); err != nil || string(back) != "hello" {
		t.Fatalf("echoed %q, %v", back, err)
	}
}

// fakeResolver fails a set number of times before it answers, as a phone does that
// connects before it is online.
type fakeResolver struct {
	failures atomic.Int32
	asked    atomic.Value
	answer   string
}

func (r *fakeResolver) Resolve(host string) (string, error) {
	r.asked.Store(host)
	if r.failures.Add(-1) >= 0 {
		return "", errors.New("offline")
	}
	return r.answer, nil
}

// An Endpoint given as a name used to fail the whole start: the device only parses
// addresses.
func TestEndpointGivenAsAName(t *testing.T) {
	resolver := &fakeResolver{answer: "not-an-address\n127.0.0.1\n::1"}
	resolver.failures.Store(1)
	destination := startAgainstPeer(t, 18111, "vpn.example.com:%d", resolver)
	echoThrough(t, 18111, destination)
	if host := resolver.asked.Load(); host != "vpn.example.com" {
		t.Errorf("looked up %v", host)
	}
}

// A silent connection is dropped when the tunnel stops, rather than being held, with
// its descriptor, for as long as the process lives.
func TestStopClosesConnectionsThatNeverSpoke(t *testing.T) {
	const port = 18112
	startAgainstPeer(t, port, "127.0.0.1:%d", nil)
	silent, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatal(err)
	}
	defer silent.Close()
	time.Sleep(100 * time.Millisecond)
	Stop()
	_ = silent.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := silent.Read(make([]byte, 1)); err == nil || errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("still open after Stop: %v", err)
	} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("still open after Stop")
	}
}

// Connections opened and left must neither pile up nor keep a real client out.
func TestSilentConnectionsCannotCrowdOutAClient(t *testing.T) {
	const port = 18113
	destination := startAgainstPeer(t, port, "127.0.0.1:%d", nil)
	var silent []net.Conn
	for range maxHandshakes + 50 {
		conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		silent = append(silent, conn)
	}
	time.Sleep(200 * time.Millisecond)
	_ = silent[0].SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := silent[0].Read(make([]byte, 1)); !errors.Is(err, io.EOF) && !isReset(err) {
		t.Errorf("the oldest silent connection was kept: %v", err)
	}
	echoThrough(t, port, destination)

	mu.Lock()
	server := current.server
	mu.Unlock()
	server.mu.Lock()
	pending := server.pending.Len()
	server.mu.Unlock()
	if pending > maxHandshakes {
		t.Errorf("%d connections are in the handshake, more than the limit", pending)
	}
}

// An association says nothing on its control connection for as long as it lasts, and
// may wait before its first datagram. Neither is a handshake that stalled.
func TestUDPAssociationIsNotAStalledHandshake(t *testing.T) {
	const port = 18114
	startAgainstPeer(t, port, "127.0.0.1:%d", nil)
	proxy := socks.NewClient(N.SystemDialer,
		M.ParseSocksaddr(fmt.Sprintf("127.0.0.1:%d", port)), socks.Version5, testUser, testPass)
	association, err := proxy.ListenPacket(context.Background(), M.ParseSocksaddr("10.9.0.2:53"))
	if err != nil {
		t.Fatal(err)
	}
	defer association.Close()

	mu.Lock()
	server := current.server
	mu.Unlock()
	server.mu.Lock()
	defer server.mu.Unlock()
	if len(server.conns) != 1 || server.pending.Len() != 0 {
		t.Errorf("%d connections, %d still counted as in the handshake", len(server.conns), server.pending.Len())
	}
}

func isReset(err error) bool {
	var op *net.OpError
	return errors.As(err, &op) && !op.Timeout()
}
