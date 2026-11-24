package libamnezia

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net/netip"
	"regexp"
	"testing"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/LostTheCodeInside/trefoil/cores/libamnezia/netstack"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/protocol/socks"
	"golang.org/x/crypto/curve25519"
)

// Both ends of a tunnel, in one process, over loopback.
//
// TestUDPThroughTheTunnel asks whether UDP survives the trip, but it needs a real
// server and a private key, so it is skipped everywhere by default — which means the
// question it exists to ask has mostly gone unanswered. This one builds the peer it
// talks to, so it runs anywhere, and it asks the question twice: once over TCP, so
// that a failure can be told apart from the tunnel simply not coming up, and then
// over UDP.
//
// The peer's AllowedIPs is a single host, so nothing here can reach the internet
// even if something is wired up wrong.
func TestLoopbackTunnel(t *testing.T) {
	for _, shape := range []struct {
		name string
		// The same parameters twice: as a client writes them in a .conf, and as the
		// peer's device takes them over its ipc. Both ends have to agree, or the
		// handshake is not merely rejected — it is unrecognisable.
		iface string
		uapi  string
	}{
		{name: "plain"},
		{
			name: "obfuscated",
			iface: "Jc = 3\nJmin = 51\nJmax = 109\nS1 = 123\nS2 = 82\n" +
				"H1 = 410000001\nH2 = 900000001\nH3 = 1500000001\nH4 = 1700000001\n",
			uapi: "jc=3\njmin=51\njmax=109\ns1=123\ns2=82\n" +
				"h1=410000001\nh2=900000001\nh3=1500000001\nh4=1700000001\n",
		},
	} {
		t.Run(shape.name, func(t *testing.T) {
			const (
				clientAddr = "10.9.0.1"
				serverAddr = "10.9.0.2"
				echoPort   = 5353
				socksPort  = 18093
			)
			client, server := newKeypair(t), newKeypair(t)

			peerNet, endpoint := startPeer(t, peerConfig{
				privateHex:  server.hex,
				peerPubHex:  client.pubHex,
				address:     serverAddr,
				peerAllowed: clientAddr,
				extra:       shape.uapi,
			})

			echoTCP(t, peerNet, netip.AddrPortFrom(netip.MustParseAddr(serverAddr), echoPort))
			echoUDP(t, peerNet, netip.AddrPortFrom(netip.MustParseAddr(serverAddr), echoPort))

			conf := fmt.Sprintf(
				"[Interface]\nPrivateKey = %s\nAddress = %s/32\nMTU = 1380\n%s\n"+
					"[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\nEndpoint = 127.0.0.1:%d\n",
				client.b64, clientAddr, shape.iface, server.pubB64, serverAddr, endpoint,
			)
			if err := Start(conf, socksPort, testUser, testPass, noProtection{}, quietLogger{}); err != nil {
				t.Fatalf("start: %v", err)
			}
			defer Stop()

			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			proxyAddr := M.ParseSocksaddr(fmt.Sprintf("127.0.0.1:%d", socksPort))
			proxy := socks.NewClient(N.SystemDialer, proxyAddr, socks.Version5, testUser, testPass)
			destination := M.ParseSocksaddr(fmt.Sprintf("%s:%d", serverAddr, echoPort))

			// TCP first. It is the control: if this fails, nothing about UDP has been
			// learned, because the tunnel never carried anything at all.
			stream, err := proxy.DialContext(ctx, "tcp", destination)
			if err != nil {
				t.Fatalf("tcp connect: %v", err)
			}
			defer stream.Close()
			_ = stream.SetDeadline(time.Now().Add(15 * time.Second))
			if _, err := stream.Write([]byte("over tcp")); err != nil {
				t.Fatalf("tcp write: %v", err)
			}
			back := make([]byte, len("over tcp"))
			if _, err := io.ReadFull(stream, back); err != nil {
				t.Fatalf("tcp read: %v", err)
			}
			if string(back) != "over tcp" {
				t.Fatalf("tcp echoed %q", back)
			}

			// The tunnel is demonstrably up, so a refusal now is the server's doing.
			// Every app on the device can reach this port; without the credentials
			// it must not be a way into the tunnel, nor a way to learn where the
			// tunnel exits.
			for _, intruder := range []struct {
				name               string
				version            socks.Version
				username, password string
			}{
				{"no credentials", socks.Version5, "", ""},
				{"wrong password", socks.Version5, testUser, "guess"},
				{"socks4", socks.Version4, testUser, ""},
			} {
				client := socks.NewClient(N.SystemDialer, proxyAddr, intruder.version, intruder.username, intruder.password)
				if stray, err := client.DialContext(ctx, "tcp", destination); err == nil {
					_ = stray.Close()
					t.Fatalf("%s: the SOCKS server let the client through", intruder.name)
				}
			}

			// And now the thing actually under test.
			packets, err := proxy.ListenPacket(ctx, destination)
			if err != nil {
				t.Fatalf("udp associate: %v", err)
			}
			defer packets.Close()
			if _, err := packets.WriteTo([]byte("over udp"), destination.UDPAddr()); err != nil {
				t.Fatalf("udp write: %v", err)
			}
			_ = packets.SetReadDeadline(time.Now().Add(15 * time.Second))
			answer := make([]byte, 64)
			n, _, err := packets.ReadFrom(answer)
			if err != nil {
				t.Fatalf("udp: nothing came back: %v", err)
			}
			if string(answer[:n]) != "over udp" {
				t.Fatalf("udp echoed %q", answer[:n])
			}
		})
	}
}

// echoTCP and echoUDP answer inside the peer's stack, so what is being measured is
// the trip through the tunnel rather than a trip to a socket on this host.
func echoTCP(t *testing.T, stack *netstack.Net, at netip.AddrPort) {
	listener, err := stack.ListenTCPAddrPort(at)
	if err != nil {
		t.Fatalf("peer tcp listen: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	go func() {
		for {
			accepted, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer accepted.Close()
				_, _ = io.Copy(accepted, accepted)
			}()
		}
	}()
}

func echoUDP(t *testing.T, stack *netstack.Net, at netip.AddrPort) {
	socket, err := stack.ListenUDPAddrPort(at)
	if err != nil {
		t.Fatalf("peer udp listen: %v", err)
	}
	t.Cleanup(func() { _ = socket.Close() })
	go func() {
		buffer := make([]byte, 1500)
		for {
			n, from, err := socket.ReadFrom(buffer)
			if err != nil {
				return
			}
			if _, err := socket.WriteTo(buffer[:n], from); err != nil {
				return
			}
		}
	}()
}

// peerConfig is the far end of the tunnel: a device with its own stack, which is
// what makes this a tunnel rather than a loopback socket wearing one.
type peerConfig struct {
	privateHex  string
	peerPubHex  string
	address     string
	peerAllowed string
	extra       string
}

func startPeer(t *testing.T, cfg peerConfig) (*netstack.Net, int) {
	peerTun, peerNet, err := netstack.CreateNetTUN(
		[]netip.Addr{netip.MustParseAddr(cfg.address)}, nil, 1380,
	)
	if err != nil {
		t.Fatalf("peer tun: %v", err)
	}
	peer := device.NewDevice(peerTun, conn.NewDefaultBind(), &device.Logger{
		Verbosef: func(string, ...any) {},
		Errorf:   func(format string, args ...any) { t.Logf("peer: "+format, args...) },
	})
	t.Cleanup(peer.Close)
	if err := peer.IpcSet(cfg.extra + fmt.Sprintf(
		"private_key=%s\nlisten_port=0\npublic_key=%s\nallowed_ip=%s/32\n",
		cfg.privateHex, cfg.peerPubHex, cfg.peerAllowed,
	)); err != nil {
		t.Fatalf("peer configure: %v", err)
	}
	if err := peer.Up(); err != nil {
		t.Fatalf("peer up: %v", err)
	}
	return peerNet, listenPort(t, peer)
}

var listenPortLine = regexp.MustCompile(`listen_port=(\d+)`)

// The peer is told to listen on port 0 and asked afterwards which one it got, so two
// runs of this test cannot collide over a hardcoded number.
func listenPort(t *testing.T, dev *device.Device) int {
	state, err := dev.IpcGet()
	if err != nil {
		t.Fatalf("peer ipc: %v", err)
	}
	match := listenPortLine.FindStringSubmatch(state)
	if match == nil {
		t.Fatalf("the peer reported no listen port")
	}
	port := 0
	if _, err := fmt.Sscanf(match[1], "%d", &port); err != nil || port == 0 {
		t.Fatalf("the peer reported listen port %q", match[1])
	}
	return port
}

type keys struct {
	hex, b64       string
	pubHex, pubB64 string
}

func newKeypair(t *testing.T) keys {
	var private [32]byte
	if _, err := rand.Read(private[:]); err != nil {
		t.Fatal(err)
	}
	// The clamping every X25519 key gets. Without it the two ends still agree, but
	// the key is not one WireGuard would ever have generated.
	private[0] &= 248
	private[31] = (private[31] & 127) | 64
	public, err := curve25519.X25519(private[:], curve25519.Basepoint)
	if err != nil {
		t.Fatal(err)
	}
	return keys{
		hex:    hex.EncodeToString(private[:]),
		b64:    base64.StdEncoding.EncodeToString(private[:]),
		pubHex: hex.EncodeToString(public),
		pubB64: base64.StdEncoding.EncodeToString(public),
	}
}

type quietLogger struct{}

func (quietLogger) Log(string) {}
