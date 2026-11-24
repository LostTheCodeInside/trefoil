// Package libamnezia runs an AmneziaWG tunnel as a SOCKS5 server on loopback.
//
// AmneziaWG is WireGuard with the handshake reshaped: junk packets before it,
// rewritten header words, custom signature packets, and — in the newer revisions —
// a protected header and randomised trailers. None of that is a field sing-box has,
// and none of it is optional: a server configured this way rejects an ordinary
// WireGuard handshake outright, so there is no degraded mode to fall back to.
//
// Rather than fork a core to add it, this follows exactly the shape libxray already
// uses here. The device is raised in userspace over gVisor's network stack, and a
// plain SOCKS5 server in front of it gives sing-box an ordinary outbound to dial.
// The TUN, DNS, routing and per-app handling all stay exactly where they were.
//
// Only gomobile-representable types cross this boundary: strings, ints, bools,
// errors, and interfaces whose methods use the same.
package libamnezia

import (
	"container/list"
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"

	"github.com/LostTheCodeInside/trefoil/cores/libamnezia/netstack"
	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"

	std_bufio "bufio"
	"time"

	"github.com/sagernet/sing/common/auth"
	"github.com/sagernet/sing/common/buf"
	"github.com/sagernet/sing/common/bufio"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/protocol/socks"
)

// Protector hands a socket to the platform so it can be kept out of the tunnel.
//
// Without it the tunnel eats itself: the device's own UDP packets are routed back
// into the TUN they are supposed to be carrying, and nothing reaches the server.
type Protector interface {
	Protect(fd int) bool
}

// Logger carries what the tunnel has to say somewhere a person can read it.
//
// The device writes to stdout by default, and a gomobile binding's stdout goes
// nowhere on Android — which meant a tunnel that would not come up had nothing to
// say about why, from either side of the boundary.
type Logger interface {
	Log(message string)
	// Verbose says whether to carry the device's running commentary as well as its
	// errors. It names peers and narrates every handshake, which is what one wants
	// while looking for a fault and not what belongs in every bug report.
	Verbose() bool
}

// Resolver looks a hostname up outside the tunnel.
//
// An Endpoint may be a name, and the device only takes an address. The lookup has to
// happen on the network underneath: asked through the tunnel, the answer would be
// needed before the tunnel it is for could carry the question.
type Resolver interface {
	// Resolve returns the host's addresses, one per line.
	Resolve(host string) (string, error)
}

// A SOCKS association with nothing flowing through it is a leak; sing-box's own
// inbound uses five minutes for the same reason.
const udpTimeout = 5 * time.Minute

// How long a client has to get through the SOCKS handshake, and how many may be doing
// so at once. sing-box is on the other end of a loopback socket and is done within
// milliseconds; anything slower is a connection somebody opened and left.
const (
	handshakeTimeout = 10 * time.Second
	maxHandshakes    = 256
)

// The wait between attempts to look up an endpoint's name. A phone that connects at
// boot is often online only some seconds later.
const (
	firstResolveDelay = time.Second
	maxResolveDelay   = 30 * time.Second
)

// Used only when the config names no resolver of its own. Two, from different
// operators, so one being unreachable from a given exit is not the end of it.
var fallbackResolvers = []netip.Addr{
	netip.MustParseAddr("1.1.1.1"),
	netip.MustParseAddr("8.8.8.8"),
}

var (
	mu      sync.Mutex
	current *instance
)

type instance struct {
	dev      *device.Device
	listener net.Listener
	server   *socksServer
	cancel   context.CancelFunc
	// The userspace stack, kept so a test in this package can reach past the SOCKS
	// server and ask the tunnel itself whether it is carrying anything.
	net *netstack.Net
}

// DialContext opens a connection through the tunnel itself, with no SOCKS server in
// the way. Exported for measurement: it is the only way to ask what the tunnel
// carries without also measuring the relay in front of it.
func DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	mu.Lock()
	stack := current
	mu.Unlock()
	if stack == nil {
		return nil, errors.New("libamnezia: not running")
	}
	return stack.net.DialContext(ctx, network, address)
}

// Stats reports the userspace stack's own counters, or "" when nothing is running.
//
// Retransmits and timeouts here are the tunnel's, not the phone's: they say whether
// packets are being lost inside the tunnel, which is the difference between a slow
// link and a broken one.
func Stats() string {
	mu.Lock()
	defer mu.Unlock()
	if current == nil {
		return ""
	}
	return current.net.Stats()
}

// Start raises the tunnel described by conf and serves SOCKS5 on 127.0.0.1:port.
//
// conf is the ordinary AmneziaWG `.conf` text, the same thing the Amnezia app hands
// out inside a `vpn://` link. It is translated here rather than on the app side
// because everything that knows what these parameters mean lives on this side of the
// boundary, and a translation written twice is a translation that drifts.
//
// username and password gate the SOCKS server. Loopback is reachable by every app on
// the device, so without them any app -- including one the user excluded from the
// VPN -- could send traffic through the tunnel and learn the server it exits from.
// Both empty serves without authentication, which only a test should ask for.
//
// resolver may be nil, in which case the system's is used.
func Start(
	conf string, socksPort int, username string, password string,
	protector Protector, resolver Resolver, logger Logger,
) error {
	mu.Lock()
	defer mu.Unlock()
	if current != nil {
		return fmt.Errorf("amneziawg is already running")
	}
	if (username == "") != (password == "") {
		return fmt.Errorf("socks credentials need both a username and a password")
	}

	settings, err := parseConf(conf)
	if err != nil {
		return err
	}

	tunDevice, tnet, err := netstack.CreateNetTUN(settings.addresses, settings.dns, settings.mtu)
	if err != nil {
		return fmt.Errorf("create tun: %w", err)
	}

	say := func(format string, args ...any) {
		if logger != nil {
			logger.Log(fmt.Sprintf(format, args...))
		}
	}

	bind := conn.NewDefaultBind()
	log := &device.Logger{
		Verbosef: device.DiscardLogf,
		Errorf:   func(format string, args ...any) { say("error: "+format, args...) },
	}
	if logger != nil && logger.Verbose() {
		log.Verbosef = func(format string, args ...any) { say(format, args...) }
	}
	dev := device.NewDevice(tunDevice, bind, log)
	if err := dev.IpcSet(settings.uapi); err != nil {
		dev.Close()
		return fmt.Errorf("configure: %w", err)
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return fmt.Errorf("bring up: %w", err)
	}

	// After Up, because the sockets do not exist until then. A failure to protect is
	// fatal rather than a warning: an unprotected socket produces a tunnel that comes
	// up and carries nothing, which is the least diagnosable outcome available.
	if err := protect(bind, protector, say); err != nil {
		dev.Close()
		return err
	}

	listener, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(socksPort)))
	if err != nil {
		dev.Close()
		return fmt.Errorf("listen on loopback: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	var authenticator *auth.Authenticator
	if username != "" {
		authenticator = auth.NewAuthenticator([]auth.User{{Username: username, Password: password}})
	}
	server := newSocksServer(authenticator, &handler{net: tnet, local: settings.addresses})
	current = &instance{dev: dev, listener: listener, server: server, cancel: cancel, net: tnet}
	go server.serve(ctx, listener)
	if settings.endpointHost != "" {
		// Not waited for. A lookup that fails is a network that is not there yet, and
		// this core is often not the one carrying the selected server: holding the
		// whole connection up for it would fail a tunnel that could have worked.
		go resolveEndpoint(ctx, dev, settings, resolver, say)
	}
	return nil
}

func Stop() {
	mu.Lock()
	defer mu.Unlock()
	if current == nil {
		return
	}
	current.cancel()
	_ = current.listener.Close()
	current.server.close()
	current.dev.Close()
	current = nil
}

// resolveEndpoint gives the peer its address once the endpoint's name has one, and
// keeps asking until it does or the tunnel is stopped.
func resolveEndpoint(
	ctx context.Context, dev *device.Device, settings *settings,
	resolver Resolver, say func(string, ...any),
) {
	for delay := firstResolveDelay; ; delay = min(delay*2, maxResolveDelay) {
		addr, err := lookupEndpoint(ctx, settings.endpointHost, resolver)
		if ctx.Err() != nil {
			return
		}
		if err == nil {
			// update_only: a device being closed has already dropped its peers, and
			// without it this would add one back.
			err = dev.IpcSet(fmt.Sprintf(
				"public_key=%s\nupdate_only=true\nendpoint=%s\n",
				settings.peerKey, netip.AddrPortFrom(addr, settings.endpointPort),
			))
		}
		if err == nil {
			return
		}
		say("error: the endpoint's name could not be looked up: %v", err)
		select {
		case <-ctx.Done():
			return
		case <-time.After(delay):
		}
	}
}

func lookupEndpoint(ctx context.Context, host string, resolver Resolver) (netip.Addr, error) {
	var answers []string
	if resolver != nil {
		lines, err := resolver.Resolve(host)
		if err != nil {
			return netip.Addr{}, err
		}
		answers = strings.Split(lines, "\n")
	} else {
		found, err := net.DefaultResolver.LookupHost(ctx, host)
		if err != nil {
			return netip.Addr{}, err
		}
		answers = found
	}
	for _, answer := range answers {
		if addr, err := netip.ParseAddr(strings.TrimSpace(answer)); err == nil {
			return addr.Unmap(), nil
		}
	}
	return netip.Addr{}, errors.New("no usable address")
}

func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return current != nil
}

// protect keeps the device's own sockets out of the tunnel.
//
// PeekLookAtSocketFd4/6 is the hook wireguard-android uses for the same purpose; the
// alternative is a whole Bind implementation for the sake of one syscall.
func protect(bind conn.Bind, protector Protector, say func(string, ...any)) error {
	peek, ok := bind.(conn.PeekLookAtSocketFd)
	if !ok {
		return fmt.Errorf("this build cannot protect its own sockets")
	}

	// Both, and each one reported. Open() makes a v4 and a v6 socket and either may
	// be absent on a given network, so the rule is that at least one has to be
	// protected — not that both must be, and not that neither need be.
	protected := 0
	for _, socket := range []struct {
		name string
		peek func() (int, error)
	}{
		{"v4", peek.PeekLookAtSocketFd4},
		{"v6", peek.PeekLookAtSocketFd6},
	} {
		fd, err := socket.peek()
		switch {
		case err != nil:
			say("no %s socket to protect: %v", socket.name, err)
		case !protector.Protect(fd):
			say("the platform refused to protect the %s socket (fd %d)", socket.name, fd)
		default:
			protected++
			say("protected the %s socket (fd %d)", socket.name, fd)
		}
	}
	if protected == 0 {
		// Fatal, not a warning. An unprotected socket sends the tunnel's own
		// handshake into the tunnel it is trying to build, and the result is a
		// connection that opens, hangs, and says nothing.
		return fmt.Errorf("could not keep the tunnel's own sockets out of the tunnel")
	}
	return nil
}

// socksServer accepts what sing-box dials, and bounds what anything else can do here.
//
// The port is on loopback, which every app on the device can reach. Credentials keep
// them out of the tunnel; these limits keep them from being a nuisance on the way to
// being refused. Connections that are opened and left would otherwise each hold a
// file descriptor for as long as the process lives, and the process is also the VPN.
type socksServer struct {
	authenticator *auth.Authenticator
	handler       *handler

	mu     sync.Mutex
	closed bool
	conns  map[net.Conn]struct{}
	// Still in the handshake, oldest first.
	pending *list.List
}

func newSocksServer(authenticator *auth.Authenticator, handler *handler) *socksServer {
	return &socksServer{
		authenticator: authenticator,
		handler:       handler,
		conns:         map[net.Conn]struct{}{},
		pending:       list.New(),
	}
}

func (s *socksServer) serve(ctx context.Context, listener net.Listener) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return
			}
			// Out of descriptors, most likely. That passes, and a server that had
			// stopped accepting would not come back when it did.
			select {
			case <-ctx.Done():
				return
			case <-time.After(50 * time.Millisecond):
			}
			continue
		}
		if entry := s.admit(conn); entry != nil {
			go s.relay(ctx, conn, entry)
		} else {
			_ = conn.Close()
		}
	}
}

// admit takes a connection into the handshake, or returns nil once the server has
// been closed.
//
// When too many are in it at once the oldest is dropped rather than the newest. A
// client that means it is through in milliseconds, so the oldest is the one that is
// not; refusing the newest instead would let a pile of silent connections lock
// sing-box out.
func (s *socksServer) admit(conn net.Conn) *list.Element {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil
	}
	if s.pending.Len() >= maxHandshakes {
		oldest := s.pending.Front()
		s.pending.Remove(oldest)
		_ = oldest.Value.(net.Conn).Close()
	}
	s.conns[conn] = struct{}{}
	return s.pending.PushBack(conn)
}

// admitted ends a connection's handshake: it is who it says and may stay as long as it
// likes.
func (s *socksServer) admitted(conn net.Conn, entry *list.Element) {
	s.mu.Lock()
	// Does nothing to an element already removed, so an eviction racing this is fine.
	s.pending.Remove(entry)
	s.mu.Unlock()
	_ = conn.SetDeadline(time.Time{})
}

func (s *socksServer) forget(conn net.Conn, entry *list.Element) {
	s.mu.Lock()
	s.pending.Remove(entry)
	delete(s.conns, conn)
	s.mu.Unlock()
	_ = conn.Close()
}

func (s *socksServer) relay(ctx context.Context, conn net.Conn, entry *list.Element) {
	defer s.forget(conn, entry)
	_ = conn.SetDeadline(time.Now().Add(handshakeTimeout))
	h := &client{handler: s.handler, admitted: func() { s.admitted(conn, entry) }}
	_ = socks.HandleConnectionEx(
		ctx, conn, std_bufio.NewReader(conn),
		s.authenticator, h, h, udpTimeout,
		M.SocksaddrFromNet(conn.RemoteAddr()), nil,
	)
}

// close ends every connection, including the ones that never said anything.
func (s *socksServer) close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = true
	for conn := range s.conns {
		_ = conn.Close()
	}
}

// client is the handler for one connection, which is the only way to learn when that
// connection has finished its handshake: each of these is called just after.
type client struct {
	*handler
	admitted func()
}

func (c *client) NewConnectionEx(
	ctx context.Context, conn net.Conn,
	source M.Socksaddr, destination M.Socksaddr,
	onClose N.CloseHandlerFunc,
) {
	c.admitted()
	c.handler.NewConnectionEx(ctx, conn, source, destination, onClose)
}

// ListenPacket rather than NewPacketConnectionEx: an association is only handed over
// with its first datagram, which a client may send whenever it likes.
func (c *client) ListenPacket(
	listenConfig net.ListenConfig, ctx context.Context, network string, address string,
) (net.PacketConn, error) {
	c.admitted()
	return c.handler.ListenPacket(listenConfig, ctx, network, address)
}

// handler carries what SOCKS5 accepts into the userspace tunnel.
type handler struct {
	net *netstack.Net
	// The tunnel's own addresses, which a UDP socket has to be bound to by name.
	// See localFor.
	local []netip.Addr
}

func (h *handler) NewConnectionEx(
	ctx context.Context, conn net.Conn,
	source M.Socksaddr, destination M.Socksaddr,
	onClose N.CloseHandlerFunc,
) {
	err := h.pipe(ctx, conn, destination)
	N.CloseOnHandshakeFailure(conn, onClose, err)
}

func (h *handler) pipe(ctx context.Context, conn net.Conn, destination M.Socksaddr) error {
	addr, err := h.resolve(destination)
	if err != nil {
		return err
	}
	remote, err := h.net.DialContextTCPAddrPort(ctx, addr)
	if err != nil {
		return err
	}
	// The SOCKS reply goes out here, before the copy starts, as sing-box's own router
	// does. Left to the copy, both directions race to send it on first use and read
	// and write the "already sent" flag from two goroutines with no lock between them.
	if err := N.ReportConnHandshakeSuccess(conn, remote); err != nil {
		remote.Close()
		return err
	}
	return bufio.CopyConn(ctx, conn, remote)
}

func (h *handler) NewPacketConnectionEx(
	ctx context.Context, conn N.PacketConn,
	source M.Socksaddr, destination M.Socksaddr,
	onClose N.CloseHandlerFunc,
) {
	// Unconnected, because one SOCKS association carries packets for many
	// destinations — a dialled socket would pin it to the first one. Bound to the
	// tunnel's own address rather than to the wildcard: see localFor.
	remote, err := h.net.ListenUDPAddrPort(netip.AddrPortFrom(h.localFor(destination), 0))
	if err != nil {
		N.CloseOnHandshakeFailure(conn, onClose, err)
		return
	}
	// Wrapped for the same reason the TCP side resolves and unmaps: a datagram is
	// addressed per packet, so there is no dial to fix it up in.
	err = bufio.CopyPacketConn(ctx, conn, &outgoing{PacketConn: bufio.NewPacketConn(remote), handler: h})
	N.CloseOnHandshakeFailure(conn, onClose, err)
}

// outgoing puts every datagram's destination through the same treatment a dialled
// address gets.
//
// Without it, UDP took whatever the client wrote: a v4-mapped address dialled as
// IPv6 on a tunnel with no IPv6 route, and a hostname written straight to the wire
// as if it were one. QUIC falls back to TCP when that happens and looks merely slow;
// a WireGuard endpoint chained through here has no fallback and simply never
// completes its handshake, which is how this was noticed.
type outgoing struct {
	N.PacketConn
	handler *handler
}

func (o *outgoing) WritePacket(buffer *buf.Buffer, destination M.Socksaddr) error {
	addr, err := o.handler.resolve(destination)
	if err != nil {
		buffer.Release()
		return err
	}
	return o.PacketConn.WritePacket(buffer, M.SocksaddrFromNetIP(addr))
}

// ListenPacket opens the association socket the SOCKS client sends through.
//
// Loopback only, and deliberately: this socket faces sing-box on the same device,
// never the network. What leaves for the network leaves through the tunnel.
func (h *handler) ListenPacket(
	listenConfig net.ListenConfig, ctx context.Context, network string, address string,
) (net.PacketConn, error) {
	return listenConfig.ListenPacket(ctx, network, "127.0.0.1:0")
}

// localFor picks the address a UDP socket for this destination is bound to.
//
// It used to be the wildcard, and that is why UDP never worked. gVisor hands a
// socket's bind address to its route lookup as the local address the route must
// start from, and 0.0.0.0 is a concrete address belonging to no interface — so every
// write failed with "network is unreachable" before a packet was ever built. TCP was
// unaffected because a dialled socket resolves its route once, at connect time, from
// an address the stack chooses itself. The symptom was a tunnel that carried web
// pages perfectly and dropped DNS, QUIC and anything a game sends.
//
// One endpoint serves one address family, so the destination decides which of the
// tunnel's addresses to use when it can, and IPv4 wins when it cannot — that being
// what nearly every config has and, before this, the only thing that was tried.
func (h *handler) localFor(destination M.Socksaddr) netip.Addr {
	wantV6 := destination.IsIP() && destination.Addr.Unmap().Is6()
	var fallback netip.Addr
	for _, addr := range h.local {
		addr = addr.Unmap()
		if addr.Is6() == wantV6 {
			return addr
		}
		if !fallback.IsValid() {
			fallback = addr
		}
	}
	if fallback.IsValid() {
		return fallback
	}
	// Unreachable through Start, which rejects a config with no Address at all, but
	// a zero value here would panic inside the stack rather than fail a write.
	return netip.IPv4Unspecified()
}

// resolve turns whatever SOCKS was given into an address the stack can dial.
//
// sing-box passes a hostname through when it has one, and the name has to be looked
// up inside the tunnel: resolving it outside would leak the query and, on a split
// DNS, answer with an address that is only reachable from the wrong side.
func (h *handler) resolve(destination M.Socksaddr) (netip.AddrPort, error) {
	if destination.IsIP() {
		// Unmapped, and that is the whole of it. An address arriving as ::ffff:1.1.1.1
		// is dialled as IPv6, and a tunnel whose config carries only an IPv4 address —
		// which is most of them — has no IPv6 route to offer, so the dial hangs until
		// something upstream gives up. Names never hit this: they come back from the
		// resolver as ordinary v4.
		return netip.AddrPortFrom(destination.Addr.Unmap(), destination.Port), nil
	}
	hosts, err := h.net.LookupHost(destination.Fqdn)
	if err != nil {
		return netip.AddrPort{}, fmt.Errorf("lookup %s: %w", destination.Fqdn, err)
	}
	for _, host := range hosts {
		if addr, err := netip.ParseAddr(host); err == nil {
			return netip.AddrPortFrom(addr.Unmap(), destination.Port), nil
		}
	}
	return netip.AddrPort{}, fmt.Errorf("lookup %s: no usable address", destination.Fqdn)
}

// ---- the configuration file ------------------------------------------------

type settings struct {
	addresses []netip.Addr
	dns       []netip.Addr
	mtu       int
	uapi      string
	// Set when the endpoint is a name rather than an address, in which case uapi
	// carries no endpoint and the peer is given one once the name has been looked up.
	endpointHost string
	endpointPort uint16
	// The peer's public key as UAPI spells it, to name the peer by.
	peerKey string
}

// Interface keys that pass through to UAPI unchanged, under a different spelling.
//
// Most of AmneziaWG's parameters are written the same way in both places — a count,
// a size, or a `lo-hi` range — so the translation is a rename. The exceptions are
// the keys, which are base64 in a config file and hex on the wire, and the booleans,
// which are `on`/`off` here and `true`/`false` there.
var ifaceKeys = map[string]string{
	"jc": "jc", "jmin": "jmin", "jmax": "jmax",
	"s1": "s1", "s2": "s2", "s3": "s3", "s4": "s4",
	"h1": "h1", "h2": "h2", "h3": "h3", "h4": "h4",
	"i1": "i1", "i2": "i2", "i3": "i3", "i4": "i4", "i5": "i5",
	"contentpaddingaddition": "content_padding_addition",
	"rekeyaftertime":         "rekey_after_time",
	"rekeytimeout":           "rekey_timeout",
	"rejectaftertime":        "reject_after_time",
	"keepalivetimeout":       "keepalive_timeout",
	"maxhandshakeattempts":   "max_handshake_attempts",
}

var ifaceBools = map[string]string{
	"randomtrailers": "random_trailers",
	"disablecookies": "disable_cookies",
}

func parseConf(conf string) (*settings, error) {
	iface, peer := sections(conf)

	// 1420 is what WireGuard uses and what most AmneziaWG configs omit. AmneziaWG puts
	// more on top of each packet than WireGuard does, and on a phone the difference
	// shows: measured against the same server over the same Wi-Fi, one stream carried
	// 227 KB/s at 1420 and 471 KB/s at 1380. Below that it stops helping — 1280, 1200
	// and 1100 all landed near 420 KB/s, and 900 was worse than any of them — which is
	// the shape of a path limit at 1380-something rather than of smaller being better.
	// A config that names its own MTU still wins; this is only the default.
	out := &settings{mtu: 1380}
	var uapi strings.Builder

	key, err := hexKey(iface["privatekey"])
	if err != nil {
		return nil, fmt.Errorf("private key: %w", err)
	}
	fmt.Fprintf(&uapi, "private_key=%s\n", key)

	for _, prefix := range strings.Split(iface["address"], ",") {
		text := strings.TrimSpace(prefix)
		if text == "" {
			continue
		}
		// An address is written with its prefix length; netstack wants the address.
		if slash := strings.IndexByte(text, '/'); slash >= 0 {
			text = text[:slash]
		}
		addr, err := netip.ParseAddr(text)
		if err != nil {
			return nil, fmt.Errorf("address %q: %w", text, err)
		}
		out.addresses = append(out.addresses, addr)
	}
	if len(out.addresses) == 0 {
		return nil, fmt.Errorf("the config has no Address")
	}

	for _, server := range strings.Split(iface["dns"], ",") {
		if addr, err := netip.ParseAddr(strings.TrimSpace(server)); err == nil {
			out.dns = append(out.dns, addr)
		}
	}
	if len(out.dns) == 0 {
		// A config need not name a resolver, and plenty do not. Without one the stack
		// has nothing to ask, and a destination given as a name fails instantly with
		// nothing to say — which is worse than the fallback being somebody's guess.
		//
		// It is only a fallback. sing-box resolves before it dials this proxy, so a
		// name reaching here at all means something upstream declined to.
		out.dns = fallbackResolvers
	}
	if mtu, err := strconv.Atoi(strings.TrimSpace(iface["mtu"])); err == nil && mtu > 0 {
		out.mtu = mtu
	}

	if hpk := strings.TrimSpace(iface["headerprotectionkey"]); hpk != "" {
		encoded, err := hexKey(hpk)
		if err != nil {
			return nil, fmt.Errorf("header protection key: %w", err)
		}
		fmt.Fprintf(&uapi, "header_protection_key=%s\n", encoded)
	}
	for name, wire := range ifaceKeys {
		if value := strings.TrimSpace(iface[name]); value != "" {
			fmt.Fprintf(&uapi, "%s=%s\n", wire, value)
		}
	}
	for name, wire := range ifaceBools {
		if value := strings.TrimSpace(iface[name]); value != "" {
			fmt.Fprintf(&uapi, "%s=%t\n", wire, truthy(value))
		}
	}

	public, err := hexKey(peer["publickey"])
	if err != nil {
		return nil, fmt.Errorf("peer public key: %w", err)
	}
	out.peerKey = public
	fmt.Fprintf(&uapi, "public_key=%s\n", public)
	if shared := strings.TrimSpace(peer["presharedkey"]); shared != "" {
		encoded, err := hexKey(shared)
		if err != nil {
			return nil, fmt.Errorf("preshared key: %w", err)
		}
		fmt.Fprintf(&uapi, "preshared_key=%s\n", encoded)
	}

	endpoint := strings.TrimSpace(peer["endpoint"])
	if endpoint == "" {
		return nil, fmt.Errorf("the config has no Endpoint")
	}
	if address, err := netip.ParseAddrPort(endpoint); err == nil {
		fmt.Fprintf(&uapi, "endpoint=%s\n", address)
	} else {
		host, portText, err := net.SplitHostPort(endpoint)
		if err != nil {
			return nil, fmt.Errorf("endpoint %q: %w", endpoint, err)
		}
		port, err := strconv.ParseUint(portText, 10, 16)
		if err != nil || port == 0 || host == "" {
			return nil, fmt.Errorf("endpoint %q is not a host and a port", endpoint)
		}
		out.endpointHost, out.endpointPort = host, uint16(port)
	}

	if keepalive := strings.TrimSpace(peer["persistentkeepalive"]); keepalive != "" {
		fmt.Fprintf(&uapi, "persistent_keepalive_interval=%s\n", keepalive)
	}
	allowed := strings.TrimSpace(peer["allowedips"])
	if allowed == "" {
		allowed = "0.0.0.0/0, ::/0"
	}
	for _, prefix := range strings.Split(allowed, ",") {
		if text := strings.TrimSpace(prefix); text != "" {
			fmt.Fprintf(&uapi, "allowed_ip=%s\n", text)
		}
	}

	out.uapi = uapi.String()
	return out, nil
}

// sections reads the `[Interface]` and `[Peer]` blocks, keys lowercased and stripped
// of spaces so `PersistentKeepalive` and `persistent_keepalive` reach the same slot.
func sections(conf string) (iface, peer map[string]string) {
	iface, peer = map[string]string{}, map[string]string{}
	current := iface
	for _, line := range strings.Split(conf, "\n") {
		text := strings.TrimSpace(line)
		if text == "" || strings.HasPrefix(text, "#") || strings.HasPrefix(text, ";") {
			continue
		}
		if strings.HasPrefix(text, "[") {
			switch strings.ToLower(strings.Trim(text, "[]")) {
			case "peer":
				current = peer
			default:
				current = iface
			}
			continue
		}
		name, value, found := strings.Cut(text, "=")
		if !found {
			continue
		}
		key := strings.ToLower(strings.NewReplacer(" ", "", "_", "", "-", "").Replace(name))
		current[key] = strings.TrimSpace(value)
	}
	return iface, peer
}

// hexKey turns a base64 key from a config file into the hex UAPI expects.
func hexKey(value string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(value))
	if err != nil {
		return "", err
	}
	if len(raw) != 32 {
		return "", fmt.Errorf("expected 32 bytes, got %d", len(raw))
	}
	return hex.EncodeToString(raw), nil
}

// truthy accepts what a config file says; UAPI only accepts what strconv does.
func truthy(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "on", "yes", "true", "1", "enabled":
		return true
	default:
		return false
	}
}
