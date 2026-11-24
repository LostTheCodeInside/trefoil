package libamnezia

import (
	"context"
	"net"
	"os"
	"testing"
	"time"

	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/protocol/socks"
)

// A datagram is addressed per packet, so nothing fixes up its destination the way a
// dial does. That is how a v4-mapped address, or a hostname, used to go to the wire
// unchanged: QUIC quietly fell back to TCP and looked slow, and a WireGuard endpoint
// chained through here never completed a handshake at all.
//
// Skipped unless TREFOIL_AWG_CONF names a real config; see TestLive.
func TestUDPThroughTheTunnel(t *testing.T) {
	path := os.Getenv("TREFOIL_AWG_CONF")
	if path == "" {
		t.Skip("set TREFOIL_AWG_CONF to a real AmneziaWG config to run this")
	}
	conf, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	const port = 18096
	if err := Start(string(conf), port, testUser, testPass, noProtection{}, testLogger{t}); err != nil {
		t.Fatalf("start: %v", err)
	}
	defer Stop()

	client := socks.NewClient(N.SystemDialer, M.ParseSocksaddr("127.0.0.1:18096"), socks.Version5, testUser, testPass)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	// A query for example.com, asked of two resolvers by address and one by name.
	query := []byte{
		0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0x00,
		0x00, 0x01, 0x00, 0x01,
	}
	for _, resolver := range []string{"8.8.8.8:53", "1.1.1.1:53"} {
		destination := M.ParseSocksaddr(resolver)
		conn, err := client.ListenPacket(ctx, destination)
		if err != nil {
			t.Errorf("%s: associate: %v", resolver, err)
			continue
		}
		began := time.Now()
		if _, err := conn.WriteTo(query, destination.UDPAddr()); err != nil {
			conn.Close()
			t.Errorf("%s: write: %v", resolver, err)
			continue
		}
		_ = conn.SetReadDeadline(time.Now().Add(8 * time.Second))
		answer := make([]byte, 512)
		n, _, err := conn.ReadFrom(answer)
		conn.Close()
		if err != nil {
			t.Errorf("%s: no answer after %s: %v", resolver, time.Since(began).Round(time.Millisecond), err)
			continue
		}
		// Same transaction id, and an answer count above zero.
		if n < 12 || answer[0] != 0x12 || answer[1] != 0x34 {
			t.Errorf("%s: %d bytes back, but not our query's answer", resolver, n)
			continue
		}
		t.Logf("%-14s answered %d bytes in %s", resolver, n, time.Since(began).Round(time.Millisecond))
	}
	_ = net.Dialer{}
}
