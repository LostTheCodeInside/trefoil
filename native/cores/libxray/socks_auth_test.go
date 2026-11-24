package libxray

import (
	"context"
	"fmt"
	"io"
	"net"
	"testing"
	"time"

	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/protocol/socks"
)

type allowAll struct{}

func (allowAll) Protect(int32) bool { return true }

// The SOCKS inbound sing-box hands traffic to, in exactly the shape the app writes
// it (lib/core/profile/xray_config.dart), must refuse anyone without the session's
// credentials. Loopback is reachable by every app on the device; without this, any of
// them could use the tunnel and learn the server it exits from.
//
// The outbound is freedom rather than the server the app would name, so the test
// needs no network: what is under test is the inbound's door, not the trip.
func TestSocksInboundRefusesWithoutCredentials(t *testing.T) {
	echo, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		for {
			conn, err := echo.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				_, _ = io.Copy(conn, conn)
			}()
		}
	}()

	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := probe.Addr().(*net.TCPAddr).Port
	_ = probe.Close()

	const user, pass = "session-user", "session-password"
	config := fmt.Sprintf(`{
	  "log": {"loglevel": "warning"},
	  "inbounds": [{
	    "tag": "socks-in",
	    "listen": "127.0.0.1",
	    "port": %d,
	    "protocol": "socks",
	    "settings": {
	      "auth": "password",
	      "accounts": [{"user": %q, "pass": %q}],
	      "udp": true,
	      "ip": "127.0.0.1"
	    },
	    "sniffing": {"enabled": false}
	  }],
	  "outbounds": [{"tag": "proxy", "protocol": "freedom"}]
	}`, port, user, pass)
	if err := Start(config, allowAll{}); err != nil {
		t.Fatalf("start: %v", err)
	}
	defer func() { _ = Stop() }()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	server := M.ParseSocksaddr(fmt.Sprintf("127.0.0.1:%d", port))
	destination := M.SocksaddrFromNet(echo.Addr())

	// The control: with the credentials, the door opens and the trip completes.
	client := socks.NewClient(N.SystemDialer, server, socks.Version5, user, pass)
	stream, err := client.DialContext(ctx, "tcp", destination)
	if err != nil {
		t.Fatalf("with credentials: %v", err)
	}
	_ = stream.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err := stream.Write([]byte("hello")); err != nil {
		t.Fatalf("write: %v", err)
	}
	back := make([]byte, 5)
	if _, err := io.ReadFull(stream, back); err != nil || string(back) != "hello" {
		t.Fatalf("echo: %q, %v", back, err)
	}
	_ = stream.Close()

	for _, intruder := range []struct {
		name               string
		version            socks.Version
		username, password string
	}{
		{"no credentials", socks.Version5, "", ""},
		{"wrong password", socks.Version5, user, "guess"},
		{"socks4", socks.Version4, user, ""},
	} {
		client := socks.NewClient(N.SystemDialer, server, intruder.version, intruder.username, intruder.password)
		stray, err := client.DialContext(ctx, "tcp", destination)
		if err != nil {
			continue
		}
		// Some refusals only surface on first use rather than at the handshake.
		_ = stray.SetDeadline(time.Now().Add(3 * time.Second))
		_, _ = stray.Write([]byte("hello"))
		n, _ := io.ReadFull(stray, make([]byte, 5))
		_ = stray.Close()
		if n == 5 {
			t.Fatalf("%s: the SOCKS inbound let the client through", intruder.name)
		}
	}
}
