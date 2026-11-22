#!/bin/bash
#
# Install this checkout's Deployment build as "iTerm2 HDR" in ~/Applications, next to
# the official iTerm2, without the two apps sharing one identity.
#
# Why this is not a plain copy of the build: macOS stores privacy grants (Documents,
# Desktop, Downloads, Full Disk Access, ...) per bundle identifier and checks each
# request against the app's code signature. A local build carries the official
# identifier com.googlecode.iterm2 and an ad hoc signature, which breaks those grants
# in two ways:
#   1. macOS attributes the programs started in the build's shells to whichever app is
#      registered under com.googlecode.iterm2, usually the official /Applications/iTerm.app.
#      The two apps then keep overwriting one stored grant, and the "would like to access
#      files in your Documents folder" prompt comes back over and over.
#   2. An ad hoc signature is a hash of the build itself, so every rebuild is a new app
#      to macOS and asks again.
# So the installed copy gets its own bundle identifier and is signed with a stable local
# certificate. A grant then survives rebuilds, and the official app keeps its own.
#
# One-time setup: create the certificate in Keychain Access (Spotlight: “Keychain
# Access”) → Certificate Assistant → Create a Certificate…, Name "iTerm2 Local HDR",
# Identity Type "Self Signed Root", Certificate Type "Code Signing". The keychain shows
# it as not trusted; that does not matter for local signing.
#
# Usage: tools/install_hdr.sh [--no-build]     (or: make install-hdr)
#   --no-build   install the existing Deployment build instead of running `make Deployment`
#
# Environment:
#   HDR_SIGN_IDENTITY  code-signing certificate name      (default "iTerm2 Local HDR")
#   HDR_BUNDLE_ID      bundle identifier of the install    (default com.googlecode.iterm2.hdr)
#   HDR_APP            install path                        (default ~/Applications/iTerm2 HDR.app)
#   BUILD_DIR          xcodebuild SYMROOT                  (default: the one the Makefile uses)
#
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY="${HDR_SIGN_IDENTITY:-iTerm2 Local HDR}"
BUNDLE_ID="${HDR_BUNDLE_ID:-com.googlecode.iterm2.hdr}"
APP="${HDR_APP:-$HOME/Applications/iTerm2 HDR.app}"
OFFICIAL_ID=com.googlecode.iterm2
APP_NAME="$(basename "$APP")"
STAGED="tmp/staged/$APP_NAME"
PREVIOUS="tmp/previous/$APP_NAME"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

BUILD=1
for arg in "$@"; do
    case "$arg" in
        --no-build) BUILD=0 ;;
        -h|--help) sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "install_hdr.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# Fail before a long build when the certificate is missing. Self-signed certificates are
# untrusted, so look among all code-signing identities, not only the valid ones.
if ! security find-identity -p codesigning | grep -qF "\"$IDENTITY\""; then
    cat >&2 <<EOF
No code-signing certificate named "$IDENTITY" in your keychain.

Create it once: open Keychain Access (Spotlight: “Keychain Access”), then
Keychain Access → Certificate Assistant → Create a Certificate…
  Name:             $IDENTITY
  Identity Type:    Self Signed Root
  Certificate Type: Code Signing
Then run this again. (Another name works too: set HDR_SIGN_IDENTITY.)
EOF
    exit 1
fi

if [[ -z "${BUILD_DIR:-}" ]]; then
    BUILD_DIR="$(xcodebuild -scheme iTerm2 -showBuildSettings 2>/dev/null | awk -F ' = ' '/^ *SYMROOT/{print $2; exit}')"
fi
if [[ -z "$BUILD_DIR" ]]; then
    echo "install_hdr.sh: could not determine BUILD_DIR; set it explicitly." >&2
    exit 1
fi

if [[ $BUILD -eq 1 ]]; then
    make Deployment BUILD_DIR="$BUILD_DIR"
fi

BUILT="$BUILD_DIR/Deployment/iTerm2.app"
if [[ ! -d "$BUILT" ]]; then
    echo "install_hdr.sh: no build at $BUILT (run without --no-build)." >&2
    exit 1
fi

echo "Staging $BUILT"
rm -rf "$STAGED"
mkdir -p "$(dirname "$STAGED")"
ditto "$BUILT" "$STAGED"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$STAGED/Contents/Info.plist"

echo "Signing with \"$IDENTITY\" (macOS may ask to use the key: choose Always Allow)"
codesign --force --deep --sign "$IDENTITY" "$STAGED"
codesign --verify --deep --strict "$STAGED"
# The point of the certificate: the designated requirement must name it, not the
# build's hash, or grants would still break on every rebuild.
if ! codesign -d -r- "$STAGED" 2>&1 | grep -q "certificate leaf"; then
    echo "install_hdr.sh: the signature does not name a certificate; grants would not survive rebuilds." >&2
    codesign -d -r- "$STAGED" >&2 || true
    exit 1
fi

if [[ -d "$APP" ]]; then
    rm -rf "$PREVIOUS"
    mkdir -p "$(dirname "$PREVIOUS")"
    mv "$APP" "$PREVIOUS"
    echo "Previous install kept at $PREVIOUS"
fi
mkdir -p "$(dirname "$APP")"
mv "$STAGED" "$APP"
echo "Installed $APP ($BUNDLE_ID)"

# LaunchServices maps a bundle identifier to an app on disk, and privacy checks follow
# that mapping. Register the install, and drop the copies that would compete with it:
# the backup (same identifier as the install) and the raw build products (the official
# identifier, so macOS could take them for iTerm2 itself). Launching a build product
# directly, e.g. with `make run`, registers it again.
"$LSREGISTER" -f "$APP"
[[ -d "$PREVIOUS" ]] && "$LSREGISTER" -u "$PREVIOUS" >/dev/null 2>&1 || true
for product in "$BUILD_DIR"/*/iTerm2.app "$BUILD_DIR"/Variant-*/*/iTerm2.app; do
    [[ -d "$product" ]] && "$LSREGISTER" -u "$product" >/dev/null 2>&1 || true
done

# Settings live under the bundle identifier, so the first install under a new
# identifier starts from a copy of the official app's settings.
if ! defaults read "$BUNDLE_ID" >/dev/null 2>&1 && defaults read "$OFFICIAL_ID" >/dev/null 2>&1; then
    defaults export "$OFFICIAL_ID" - | defaults import "$BUNDLE_ID" -
    echo "Copied settings from $OFFICIAL_ID to $BUNDLE_ID (first install)"
fi

if pgrep -qf "$APP/Contents/MacOS/iTerm2"; then
    echo
    echo "$APP_NAME is running the old build: quit it (⌘Q) and reopen it."
fi
