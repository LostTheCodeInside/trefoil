# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Routing

- The action buttons in the rule sheet no longer break a word in two ("Langs-ung"). They
  drop the check mark first, then shrink a little, and become a list when that is not
  enough. At the largest font sizes the match field no longer runs off its edge.

## [1.0.1] - 2026-11-24

### Cores

- Xray-core v26.11.9. sing-box 1.14.4 is still the newest stable release.
- XHTTP and VLESS encryption now run on Xray. XHTTP links used to be read as plain TCP
  and could never connect.
- `chi` 5.4.0 and `go-jose` 4.1.6, for published advisories. Neither flawed function was
  part of the app.

### Tunnel

- Reconnecting and switching settings no longer takes the VPN down for a moment. Only
  changing strict route or the per-app list still makes Android build a new one.
- The tunnel comes back by itself after Android kills the app, and after an app update.
- A phone waking from deep sleep no longer restarts a healthy tunnel.
- A second tap on Connect cannot start a second tunnel, and a connect that is still
  under way can be called off.
- AmneziaWG and WireGuard servers named by host instead of IP connect.
- The core is controlled through a socket only this app can open, instead of a fixed
  port on loopback. A stuck core no longer freezes the app.

### Servers

- A server the cores would refuse says why in the list and is left out, instead of
  failing every connection. Tapping it while connected keeps the current server.
- Imports: Hysteria2 port hopping, a `+` in a key, percent-encoded Shadowsocks keys,
  Hysteria 1 `obfsParam`, TCP with an HTTP header. A plugin or transport no core supports is named, not dropped.
- Custom DNS addresses keep their path and port (NextDNS profiles work).

### Routing

- Custom rules are applied in the order they are listed.

### Data

- A damaged profile keeps every entry that can be read and sets a copy of the old file
  aside, instead of starting empty and overwriting it.
- Backups are encrypted with a key from Argon2id. Older backups still open; **new
  backups do not open in 1.0.0**.
- Traffic totals survive a write that failed, and go to the server that carried them.

### App

- The reminder to reconnect is a strip above the navigation bar and no longer holds back
  error messages.
- Restoring a backup and closing all connections ask first. A single connection can be
  closed, and a rule can be deleted from its sheet.
- The add sheet stays open, with the text in it, when a link cannot be read.
- Dismissing the language dialog no longer resets the language. A setting that could not
  be saved says so and switches back.
- Routing presets and dates are translated, plurals are right, and configs and logs read
  left to right in Arabic and Persian.

### Project

- A release is built outside the home directory, and refused if an APK names it.
- The Go and Kotlin tests run in CI. Unused platform folders and the `cupertino_icons`
  package are gone.
- Added a security policy and issue forms.

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
