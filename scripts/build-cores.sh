#!/usr/bin/env bash
# Build libcores.aar — sing-box and Xray-core in one gomobile binding.
#
# Why one binding and not two: every gomobile .aar carries its own copy of the go.Seq
# runtime classes and its own Go runtime inside its .so. Two of them in one APK are
# rejected as duplicate classes, and forcing them together would have two Go runtimes
# registering JNI methods on the same class. Binding both packages in a single module
# gives one runtime, one go.Seq, and a smaller artifact than the two separately.
#
# sing-box carries the tunnel. Xray is only reached for servers sing-box cannot run
# (post-quantum REALITY) and is driven through a loopback SOCKS inbound.
#
# Usage:
#   ./scripts/build-cores.sh                      # release ABIs
#   ABIS=android/arm64 ./scripts/build-cores.sh   # single ABI, faster for development
#   ./scripts/build-cores.sh --check-only         # just report versions, build nothing
#
# The version check reports and never bumps. Following upstream automatically would
# quietly break reproducibility -- the point of pinning is that this script produces
# the same artifact today as it did last week. Set SKIP_VERSION_CHECK=1 to skip it.
set -euo pipefail

ABIS="${ABIS:-android/arm64,android/arm,android/amd64}"
ANDROID_API="${ANDROID_API:-24}"
GOMOBILE_VERSION="${GOMOBILE_VERSION:-v0.1.12}"

# The Go toolchain is an input like any other, so it is pinned too. Whatever Go is
# installed fetches this one on first use. Without it the artifact depends on the
# host, and a new runtime is not something a tunnel core should pick up unannounced.
# Xray-core requires Go 1.27 since v26.9.
export GOTOOLCHAIN="${GOTOOLCHAIN:-go1.27.1}"

# Set to 1 to skip the upstream version check -- offline builds, or a CI runner that
# should not depend on GitHub being reachable.
SKIP_VERSION_CHECK="${SKIP_VERSION_CHECK:-0}"

# --check-only reports the pinned and available versions and stops. Useful on its own:
# the question "is there a newer core?" should not cost a fifteen-minute build.
CHECK_ONLY=0
[[ "${1:-}" == "--check-only" ]] && CHECK_ONLY=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/native/cores"
OUT_DIR="$REPO_ROOT/android/app/libs"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- JDK 17 ----------------------------------------------------------------
# gomobile's bind step is only validated against 17 upstream; newer JDKs emit class
# files it rejects. Located without touching the system default.
find_jdk17() {
  [[ -n "${JAVA_HOME:-}" ]] && "$JAVA_HOME/bin/java" --version 2>/dev/null | grep -q 'openjdk 17' && { echo "$JAVA_HOME"; return; }
  for c in "$HOME"/.jdks/jdk-17* /usr/lib/jvm/java-17-openjdk* /opt/android-studio/jbr "$HOME"/.sdkman/candidates/java/17*; do
    [[ -x "$c/bin/java" ]] && "$c/bin/java" --version 2>/dev/null | grep -q 'openjdk 17' && { echo "$c"; return; }
  done
}
JAVA_HOME="$(find_jdk17)"
[[ -n "$JAVA_HOME" ]] || die "JDK 17 not found. Install it (no sudo needed):
  mkdir -p ~/.jdks && curl -fsSL 'https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse' | tar xz -C ~/.jdks"
export JAVA_HOME
log "JDK 17: $JAVA_HOME"

# --- Android SDK/NDK -------------------------------------------------------
for c in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Android/Sdk" "$HOME/.local/lib/android/sdk"; do
  [[ -n "$c" && -f "$c/licenses/android-sdk-license" ]] && { export ANDROID_HOME="$c"; break; }
done
[[ -n "${ANDROID_HOME:-}" ]] || die "Android SDK not found; set ANDROID_HOME."
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -1)}"
[[ -d "$ANDROID_NDK_HOME" ]] || die "Android NDK not found under $ANDROID_HOME/ndk."
log "Android SDK: $ANDROID_HOME"

# --- gomobile (SagerNet fork; upstream cannot build sing-box) --------------
GOBIN="$(go env GOPATH)/bin"
export PATH="$PATH:$GOBIN"
if [[ ! -x "$GOBIN/gobind" ]]; then
  log "Installing gomobile $GOMOBILE_VERSION"
  go install "github.com/sagernet/gomobile/cmd/gomobile@$GOMOBILE_VERSION"
  go install "github.com/sagernet/gomobile/cmd/gobind@$GOMOBILE_VERSION"
fi

# --- Pinned versions -------------------------------------------------------
# go.mod is the single source of truth. Reading it here rather than repeating the
# version in this script is what stops the two drifting apart -- the .aar would then
# report a version it was not built from.
cd "$SRC_DIR"
SING_BOX_VERSION="$(go list -m -f '{{.Version}}' github.com/sagernet/sing-box)"
XRAY_VERSION="$(go list -m -f '{{.Version}}' github.com/xtls/xray-core)"
# Xray tags releases as v26.x but its module path has no /vN suffix, so Go pins it by
# commit; the pseudo-version's trailing segment is that commit.
XRAY_COMMIT="${XRAY_VERSION##*-}"
log "Pinned: sing-box $SING_BOX_VERSION, xray-core @${XRAY_COMMIT}"

# --- Upstream version check ------------------------------------------------
# Reports only. Bumping automatically would quietly break reproducibility: the point
# of pinning is that this script produces the same artifact today as it did last week.
#
# The comparison is deliberately not "is the pinned version different from
# releases/latest". GitHub's "latest" is the most recently *published* release, which
# is not always the highest version -- a backport to an older line takes that slot and
# a naive check then tells you to downgrade.
check_upstream() {
  [[ "$SKIP_VERSION_CHECK" == "1" ]] && return 0
  command -v curl >/dev/null && command -v python3 >/dev/null || return 0

  local singbox_releases xray_releases xray_tags
  singbox_releases="$(fetch 'https://api.github.com/repos/SagerNet/sing-box/releases?per_page=100')"
  xray_releases="$(fetch 'https://api.github.com/repos/XTLS/Xray-core/releases?per_page=100')"
  # Needed to turn the pinned commit back into a tag, since go.mod holds a commit.
  xray_tags="$(fetch 'https://api.github.com/repos/XTLS/Xray-core/tags?per_page=100')"

  SING_BOX_VERSION="$SING_BOX_VERSION" XRAY_COMMIT="$XRAY_COMMIT" python3 -c '
import json, os, re, sys

def version_key(tag):
    """Sorts release tags by number, so v26.7.28 outranks v26.3.27."""
    return [int(part) for part in re.findall(r"\d+", tag)] or [0]

PRERELEASE = re.compile(r"alpha|beta|-rc|\.rc", re.I)

def newest(payload, name):
    """Highest stable release tag.

    Filtered by tag name, not by GitHub'"'"'s prerelease flag: Xray marks every one of
    its releases as a prerelease, so trusting the flag would discard everything
    current and recommend a downgrade to a year-old tag.

    An unreadable answer is said out loud: staying quiet reads as "up to date", and
    an anonymous client runs into GitHub'"'"'s rate limit after 60 requests an hour.
    """
    try:
        releases = json.loads(payload)
    except Exception:
        releases = None
    if not isinstance(releases, list):
        print(f"{YELLOW}==>{RESET} {name}: could not read its releases from GitHub "
              "(offline or rate-limited); not checked")
        return None
    stable = [
        r["tag_name"] for r in releases
        if isinstance(r, dict) and not r.get("draft") and not PRERELEASE.search(r["tag_name"])
    ]
    return max(stable, key=version_key, default=None)

YELLOW, RESET = "\033[1;33m", "\033[0m"

def report(name, current, latest, command):
    if not latest or not current:
        return
    if version_key(latest) <= version_key(current):
        return
    print(f"{YELLOW}==>{RESET} {name} {latest} is available (pinned: {current})")
    print(f"    to take it:  {command}")

# A marker rather than a NUL byte: bash strips NULs out of variables.
singbox_payload, xray_payload, tags_payload = sys.stdin.read().split("\n@@SPLIT@@\n")

latest_singbox = newest(singbox_payload, "sing-box")
report(
    "sing-box",
    os.environ["SING_BOX_VERSION"],
    latest_singbox,
    f"(cd native/cores && go get github.com/sagernet/sing-box@{latest_singbox} && go mod tidy)",
)

# Map the pinned commit back to its tag; without that there is nothing to compare a
# version against, and comparing commits only tells you "different", not "newer".
pinned_tag = None
try:
    for tag in json.loads(tags_payload):
        if tag["commit"]["sha"].startswith(os.environ["XRAY_COMMIT"]):
            pinned_tag = tag["name"]
            break
except Exception:
    pass

latest_xray = newest(xray_payload, "Xray-core")

# Xray has no /vN module path, so go.mod can only hold a commit -- the bump command
# needs the commit behind the tag, not the tag itself.
latest_xray_commit = None
try:
    for tag in json.loads(tags_payload):
        if tag["name"] == latest_xray:
            latest_xray_commit = tag["commit"]["sha"]
            break
except Exception:
    pass

if pinned_tag is None:
    if latest_xray:
        print(f"{YELLOW}==>{RESET} Xray-core: pinned commit is not on a release tag; "
              f"newest release is {latest_xray}")
else:
    report(
        "Xray-core",
        pinned_tag,
        latest_xray,
        f"(cd native/cores && go get github.com/xtls/xray-core@{latest_xray_commit} && go mod tidy)",
    )
' <<< "$singbox_releases"$'\n@@SPLIT@@\n'"$xray_releases"$'\n@@SPLIT@@\n'"$xray_tags"
}

# One GitHub request. Silent on any failure -- rate limits, no network, unexpected
# JSON -- because none of that should stop a build.
fetch() {
  curl -fsS --max-time 20 -H "Accept: application/vnd.github+json" "$1" 2>/dev/null || true
}

check_upstream
[[ "$CHECK_ONLY" == "1" ]] && exit 0

# --- Build -----------------------------------------------------------------
# Tags mirror sing-box's own cmd/internal/build_libbox for the Android target.
TAGS="with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,badlinkname,tfogo_checklinkname0"
TAGS="$TAGS,with_tailscale,ts_omit_logtail,ts_omit_ssh,ts_omit_drive,ts_omit_taildrop"
TAGS="$TAGS,ts_omit_webclient,ts_omit_doctor,ts_omit_capture,ts_omit_kube,ts_omit_aws,ts_omit_synology,ts_omit_bird"

# -checklinkname=0 is required by both cores: sing-box's own build sets it, and Xray
# pulls in github.com/wlynxg/anet which reaches into the net package via go:linkname.
LDFLAGS="-X github.com/sagernet/sing-box/constant.Version=$SING_BOX_VERSION"
# The GODEBUG defaults go where sing-box's own build puts them. This used to name
# internal/godebug.defaultGODEBUG, which does not exist, and -X ignores a symbol it
# cannot find -- so the setting never took effect and nothing said so.
LDFLAGS="$LDFLAGS -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -s -w -buildid= -checklinkname=0"

mkdir -p "$OUT_DIR"
# Stale single-core artifacts would reintroduce the duplicate-class failure.
rm -f "$OUT_DIR"/libbox.aar "$OUT_DIR"/libxray.aar "$OUT_DIR"/libbox-sources.jar "$OUT_DIR"/libxray-sources.jar

log "Building libcores.aar for [$ABIS] (several minutes)"
"$GOBIN/gomobile" bind -v \
  -o "$OUT_DIR/libcores.aar" \
  -target "$ABIS" \
  -androidapi "$ANDROID_API" \
  -javapkg=io.nekohasekai \
  -libname=cores \
  -trimpath -buildvcs=false \
  -ldflags "$LDFLAGS" \
  -tags "$TAGS" \
  github.com/sagernet/sing-box/experimental/libbox \
  github.com/LostTheCodeInside/trefoil/cores/libxray \
  github.com/LostTheCodeInside/trefoil/cores/libamnezia \
  github.com/LostTheCodeInside/trefoil/cores/libruntime \
  github.com/LostTheCodeInside/trefoil/cores/libkdf

log "Done: $OUT_DIR/libcores.aar ($(du -h "$OUT_DIR/libcores.aar" | cut -f1))"
