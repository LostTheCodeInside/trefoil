# Building Trefoil

How the app is put together, built, released and tested. The short version is in the
[README](../README.md).

## How the cores fit together

sing-box carries every tunnel. Xray is reached only for servers sing-box cannot run:
post-quantum REALITY (`pqv` / ML-DSA-65), XHTTP and VLESS encryption, none of which
sing-box has a config field for. Such a server runs inside Xray behind a loopback SOCKS5
inbound that sing-box dials as an ordinary proxy outbound, so the TUN, DNS, routing and
per-app rules stay in one place regardless of which core carries the traffic. That
inbound takes a fresh port and credentials on every connect, so other apps on the
device cannot use it.

Supported share links: `vless://` (incl. REALITY), `vmess://`, `trojan://`, `ss://`
(SIP002 + legacy), `hysteria2://`, `hysteria://`, `tuic://`, `anytls://`, `socks://`,
`wireguard://`. A WireGuard `.conf` file can be pasted where a link goes.
Subscriptions may be a link list, a base64-wrapped one, or a Clash/Meta YAML
document.

Links that need Xray are detected and routed to it automatically; the server list shows
which core each server will use.

## Build

Neither core is on Maven; both are built from source into a single `.aar`. The script
pins every input and needs no `sudo`:

```bash
./scripts/build-cores.sh                      # arm64 + arm + x86_64, ~15 min
ABIS=android/arm64 ./scripts/build-cores.sh   # single ABI, faster for development
./scripts/build-cores.sh --check-only         # just report versions, build nothing
```

Every build reports whether a newer core is out, and prints the exact command to take
it. It never bumps on its own — the point of pinning is that this script produces the
same artifact today as it did last week. `SKIP_VERSION_CHECK=1` skips the check for
offline builds.

`native/cores/go.mod` is the single source of truth for both versions; the script reads
them from there rather than repeating them, so the `.aar` cannot report a version it
was not built from.

It requires Go (the script fetches the pinned toolchain, go1.27.1, on first use), JDK
17 (auto-located; it prints how to install one if missing), and the Android SDK with
an NDK. The result lands in `android/app/libs/libcores.aar`.

Note that the cores cannot be updated from inside the app: they are native libraries
inside the APK, and Android forbids loading executable code from an app's own data
directory. A core update is an app update.

The two cores must share one binding: every gomobile `.aar` ships its own copy of the
`go.Seq` runtime classes and its own Go runtime, so two of them in one APK are
rejected as duplicate classes. Bound together they also share a Go runtime, which
makes the combined artifact barely larger than sing-box alone.

Then the app itself:

```bash
flutter pub get
flutter run                            # or: flutter build apk --split-per-abi
```

Use `--split-per-abi` for releases: `libcores.so` is ~70 MB per ABI, so a universal
APK is roughly three times larger than any device needs.

The Gradle build refuses to run if `libcores.aar` is missing an ABI the app declares.
That mismatch is easy to reach — one `ABIS=android/arm64 ./scripts/build-cores.sh` for
a quick test overwrites the full artifact — and it is invisible until a user installs
the affected split and finds the tunnel simply will not start.

## Releases

The app reads `latest.json` from the newest release once per launch, and on demand from
Settings → About. It downloads the APK for the phone's ABI and hands it to Android's
installer once the hash, version and signing key match. One command publishes a
release, signed with the local release key, which never leaves the machine:

```bash
# bump `version:` in pubspec.yaml, add a matching `## [x.y.z]` to CHANGELOG.md, commit, push
./scripts/release.sh
./scripts/release.sh --dry-run   # build and write build/release/, publish nothing
```

Set `RELEASE_CHECK` to a command to have it run on the staged files before anything is
published; if it fails, the release stops.

The APKs are built in a checkout of `HEAD` at `/tmp/trefoil-release` (`RELEASE_WORK_DIR`
changes it), because the Dart compiler writes the project's path into the app. An APK
that still names the home directory is refused.

It needs the GitHub CLI signed in with write access to the repository. A fork that
publishes its own builds has to change `REPO` and `RELEASE_CERT_SHA256` in that script,
and `releaseManifestUrl` in `lib/core/app_update.dart`.

## Verifying generated configs

`ConfigBuilder` output can be checked against the real core without a device:

```bash
dart run tool/emit_config.dart 'vless://…' | sing-box check -c /dev/stdin
```

## Localization

English, Indonesian, Chinese, Persian, Russian, Arabic, Vietnamese and Turkish, in
`lib/l10n/*.arb`. `flutter pub get` writes `app_localizations*.dart` beside them; those
are build products and are not in the repository.

Adding a language means one more `.arb` file; nothing below the UI layer holds display
strings, and the picker reads its list from the generated locales. Four tests enforce
that the files stay in step — identical keys, identical placeholders, no file left as
a copy of the template, and that right-to-left locales actually lay out RTL. Every one
of those failures is otherwise invisible: they degrade quietly into English or into a
subtly wrong layout.

## CI

`.github/workflows/ci.yml` runs `flutter analyze`, the format check and the Dart tests on
every push and pull request, without the cores.

`.github/workflows/native.yml` runs when `native/` or `android/` changes: `go vet` and
the Go tests with the race detector, then the Kotlin unit tests. Those compile against
`libcores.aar`, which is built once per version of its sources and cached.

The same locally:

```bash
(cd native/cores && go test -race -ldflags=-checklinkname=0 ./libamnezia/... ./libkdf ./libxray)
(cd android && ./gradlew :app:testDebugUnitTest)
```

## Status

Android only. An iOS version would need a `NetworkExtension` target and an Apple
Developer account, and is not started.
