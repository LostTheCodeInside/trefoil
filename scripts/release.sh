#!/usr/bin/env bash
# Publish a release for the in-app updater.
#
# Builds the per-ABI APKs with the release key, writes latest.json beside them, and
# publishes both as a GitHub release of $REPO. Every installed copy reads the newest
# release's latest.json from $BASE_URL.
#
# Usage, from a clean tree whose HEAD is pushed, after bumping `version:` in
# pubspec.yaml and giving that version its own section in CHANGELOG.md:
#   ./scripts/release.sh
#   ./scripts/release.sh --dry-run    # build into build/release/, publish nothing
#
# Needs the GitHub CLI (`gh`), signed in with write access to $REPO.
#
# The release key never leaves this machine. GitHub only ever holds signed APKs, and
# an installed copy refuses an update signed with any other key: whoever controls the
# repository can withhold an update, but cannot ship one.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="LostTheCodeInside/trefoil"
BASE_URL="https://github.com/$REPO/releases/latest/download"
# The certificate installed copies carry. Every published APK must match it.
RELEASE_CERT_SHA256="253e25a04c64afde913dd82f5e13470e3d95b262589728935be8980d64758c33"
ABIS=(arm64-v8a armeabi-v7a x86_64)
STAGE="build/release"

die() {
  echo "release: $*" >&2
  exit 1
}

dry_run=0
[[ "${1:-}" == "--dry-run" ]] && dry_run=1

[[ -f android/key.properties ]] ||
  die "android/key.properties is missing; a debug-signed build can never update an installed copy"
[[ -z "$(git status --porcelain)" ]] || die "commit or stash first, so the release matches a commit"

version="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml)"
name="${version%%+*}"
build="${version##*+}"
[[ "$name" != "$version" && "$build" =~ ^[0-9]+$ ]] ||
  die "pubspec.yaml version must look like 1.2.3+4, not '$version'"
grep -qF "## [$name]" CHANGELOG.md || die "CHANGELOG.md has no '## [$name]' section for the release notes"
tag="v$name"
commit="$(git rev-parse HEAD)"
if ! ((dry_run)); then
  gh auth status >/dev/null 2>&1 || die "gh is not signed in; run: gh auth login"
  # The tag is made on GitHub, at this commit, so the commit has to be there.
  gh api "repos/$REPO/commits/$commit" --silent 2>/dev/null ||
    die "HEAD ($commit) is not on GitHub; push it first"
  gh release view "$tag" --repo "$REPO" >/dev/null 2>&1 && die "release $tag already exists"
fi

# Nothing goes out over a build that is not older than it.
live_json="$(mktemp)"
trap 'rm -f "$live_json"' EXIT
status="$(curl -sSL --max-time 20 -o "$live_json" -w '%{http_code}' "$BASE_URL/latest.json" || true)"
case "$status" in
  200) live="$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1])).get("build", 0)))' "$live_json")" ;;
  404) live=0 ;; # the first release
  *) die "cannot read $BASE_URL/latest.json (HTTP ${status:-none})" ;;
esac
((build > live)) || die "build $build is not newer than the live build $live; bump version: in pubspec.yaml"

tools="$(ls -d "${ANDROID_HOME:-$HOME/Android/Sdk}"/build-tools/*/ 2>/dev/null | sort -V | tail -1)"
[[ -x "${tools}apksigner" && -x "${tools}aapt2" ]] ||
  die "Android build-tools (apksigner, aapt2) not found; set ANDROID_HOME"

flutter build apk --release --split-per-abi

rm -rf "$STAGE"
mkdir -p "$STAGE"
for abi in "${ABIS[@]}"; do
  src="build/app/outputs/flutter-apk/app-$abi-release.apk"
  [[ -f "$src" ]] || die "$src was not built"
  "${tools}apksigner" verify --print-certs "$src" |
    grep -qi "certificate SHA-256 digest: $RELEASE_CERT_SHA256" ||
    die "$src is not signed with the release key"
  cp "$src" "$STAGE/trefoil-$name-$abi.apk"
done

python3 - "$name" "$build" "$STAGE" "${tools}aapt2" "${ABIS[@]}" <<'PY'
import datetime, hashlib, json, os, re, subprocess, sys

name, build, stage, aapt2, abis = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5:]


def notes():
    text = open("CHANGELOG.md", encoding="utf-8").read()
    section = re.search(r"^## \[" + re.escape(name) + r"\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.M | re.S)
    lines = []
    for line in section.group(1).splitlines():
        text = line.strip()
        # Wrapped lines are joined back up: the phone wraps them to its own width.
        joins = text and not text.startswith(("- ", "#"))
        if joins and lines and lines[-1] and not lines[-1].startswith("#"):
            lines[-1] += " " + text
        else:
            lines.append(text if not text.startswith("- ") else line.rstrip())
    out = "\n".join(lines).replace("**", "").replace("`", "")
    out = re.sub(r"^#+ ", "", out, flags=re.M)
    out = re.sub(r"\n{3,}", "\n\n", out).strip()
    # The app shows what fits on a screen or two; the full list stays in CHANGELOG.md.
    return out if len(out) <= 6000 else out[:6000].rsplit("\n", 1)[0] + "\n…"


apks = []
for abi in abis:
    file = f"trefoil-{name}-{abi}.apk"
    path = os.path.join(stage, file)
    badging = subprocess.run([aapt2, "dump", "badging", path], capture_output=True, text=True, check=True).stdout
    if f"versionName='{name}'" not in badging:
        sys.exit(f"release: {file} does not carry versionName {name}")
    digest = hashlib.sha256()
    with open(path, "rb") as apk:
        for chunk in iter(lambda: apk.read(1 << 20), b""):
            digest.update(chunk)
    apks.append({
        "abi": abi,
        # Android's own number for this APK, ABI offset included: what the app compares.
        "versionCode": int(re.search(r"versionCode='(\d+)'", badging).group(1)),
        "url": file,
        "size": os.path.getsize(path),
        "sha256": digest.hexdigest(),
    })

# The same section, as written, for the release page on GitHub.
section = re.search(r"^## \[" + re.escape(name) + r"\][^\n]*\n(.*?)(?=^## \[|\Z)",
                    open("CHANGELOG.md", encoding="utf-8").read(), re.M | re.S)
with open(os.path.join(stage, "notes.md"), "w", encoding="utf-8") as out:
    out.write(section.group(1).strip() + "\n")

with open(os.path.join(stage, "latest.json"), "w", encoding="utf-8") as out:
    json.dump({
        "schema": 1,
        "versionName": name,
        "build": build,
        "publishedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "notes": notes(),
        "apks": apks,
    }, out, indent=2, ensure_ascii=False)
    out.write("\n")
PY

if ((dry_run)); then
  echo "release: dry run; $name (build $build) is ready in $STAGE/"
  exit 0
fi

# Uploaded as a draft and published in one step: a draft's files are not served, so
# no phone ever reads a manifest naming a file that is still uploading.
gh release create "$tag" --repo "$REPO" --draft --target "$commit" \
  --title "Trefoil $name" --notes-file "$STAGE/notes.md" \
  "$STAGE"/*.apk "$STAGE/latest.json"
gh release edit "$tag" --repo "$REPO" --draft=false --latest

# Read back through the public address: a release that is not the newest, or not
# published, would otherwise look exactly like a successful one.
served="$(curl -fsSL --max-time 20 -H 'Cache-Control: no-cache' "$BASE_URL/latest.json")" ||
  die "published, but $BASE_URL/latest.json cannot be read"
python3 -c 'import json,sys; sys.exit(json.loads(sys.argv[1]).get("build") != int(sys.argv[2]))' \
  "$served" "$build" || die "published, but $BASE_URL/latest.json still serves another build"
for apk in "$STAGE"/*.apk; do
  curl -fsSIL --max-time 20 "$BASE_URL/$(basename "$apk")" >/dev/null ||
    die "published, but $BASE_URL/$(basename "$apk") is not served"
done
echo "release: published $name (build $build) as $tag at https://github.com/$REPO/releases/tag/$tag"
