# Changelog

All notable changes to this project are documented here.

## [Unreleased]

## [1.0.0] - 2026-11-24

First public release, under the GPL-3.0-or-later license.

### Servers

- Import a subscription (link list, base64 or Clash/Meta YAML), paste a share link, scan
  a QR code, or paste a WireGuard or AmneziaWG `.conf`.
- `vless://` (incl. REALITY), `vmess://`, `trojan://`, `ss://`, `hysteria2://`,
  `hysteria://`, `tuic://`, `anytls://`, `socks://` and `wireguard://`.
- Servers are grouped by subscription. Each group can be refreshed, folded or removed
  from its heading.
- Latency tests and switching between servers work without reconnecting.

### Cores

- sing-box 1.14.4 carries every tunnel. Xray-core v26.10.21 runs the servers sing-box
  cannot (post-quantum REALITY), and amneziawg-go runs AmneziaWG. The server list shows
  which core each server uses.

### Routing

- Per-app control, ad-blocking and direct-routing presets, and your own rules by
  domain, IP range or app. A rule can send traffic to the proxy, straight out, to a
  chosen server, to Cloudflare WARP, or block it.
- Cloudflare WARP as a rule target, as the default route, or as a second hop behind the
  proxy.

### App

- Quick Settings tile, home screen widget, throughput in the notification, a live
  connections view, per-server traffic totals and core logs.
- Encrypted backup and restore of servers, subscriptions and settings.
- In-app updates from this repository's GitHub releases. An update installs only when
  its hash, version and signing key match.
- English, Indonesian, Chinese, Persian, Russian, Arabic, Vietnamese and Turkish.
