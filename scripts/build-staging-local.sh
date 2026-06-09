#!/usr/bin/env bash
set -euo pipefail

# build-staging-local.sh
#
# One-command rebuild of the personal "cmux STAGING" daily driver from YOUR FORK
# (whatever branch is currently checked out, normally `main`), installed to
# /Applications as an isolated app that coexists with the official cmux.
#
# Why this exists (and differs from promote-personal-release.sh):
#   This Mac has only Xcode-beta / the macOS 26 SDK. Ghostty's CLI helper needs
#   zig 0.15.2 *exactly*, which cannot link against that SDK (and zig 0.16 can't
#   build Ghostty). So instead of compiling the helper, we:
#     1. Build the whole Swift app ad-hoc-signed with the helper STUBBED
#        (CMUX_SKIP_ZIG_BUILD=1) — everything else compiles fine.
#     2. Graft the real, working universal `ghostty` helper + its share resources
#        out of the installed official cmux.app (same cmux version).
#   cmux's in-app terminal renders via the prebuilt GhosttyKit.xcframework that is
#   compiled into the Swift app, so the grafted CLI helper only covers auxiliary
#   `ghostty` command-line features.
#
# Isolation: bundle id com.cmuxterm.app.staging + display name "cmux STAGING" keep
# it fully separate from the official app (own Dock icon, own window layout, own
# UserDefaults). Shortcuts in ~/.config/cmux/cmux.json are path-keyed and shared.
#
# Usage:
#   ./scripts/build-staging-local.sh            # build current branch -> install -> launch
#   ./scripts/build-staging-local.sh --no-open  # don't launch at the end
#
# Re-seed settings from the official app again (rare): delete the marker printed
# at the end and re-run.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OPEN_AFTER=1
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN_AFTER=0 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

OFFICIAL_APP="/Applications/cmux.app"
OFFICIAL_BUNDLE_ID="com.cmuxterm.app"
STAGING_BUNDLE_ID="com.cmuxterm.app.staging"
STAGING_APP_NAME="cmux STAGING"
INSTALL_PATH="/Applications/${STAGING_APP_NAME}.app"
DERIVED="$HOME/.cache/cmux-staging-build"
APP_SUPPORT="$HOME/Library/Application Support/cmux"
MIGRATED_MARKER="$APP_SUPPORT/.staging-local-migrated"

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
COMMIT="$(git rev-parse --short=9 HEAD 2>/dev/null || echo '?')"
echo "==> Building '${STAGING_APP_NAME}' from fork branch '${BRANCH}' @ ${COMMIT}"

# The graft source must exist and should match the version we're building.
if [[ ! -d "$OFFICIAL_APP" ]]; then
  echo "error: official $OFFICIAL_APP not found — needed for the Ghostty helper graft." >&2
  echo "       Install it first:  brew install --cask cmux" >&2
  exit 1
fi
OFFICIAL_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$OFFICIAL_APP/Contents/Info.plist" 2>/dev/null || echo '?')"
FORK_VER="$(grep -m1 'MARKETING_VERSION = ' cmux.xcodeproj/project.pbxproj | sed 's/.*= //; s/;//; s/ //g')"
echo "==> Fork version ${FORK_VER}; official (graft source) version ${OFFICIAL_VER}"
if [[ "$OFFICIAL_VER" != "$FORK_VER" ]]; then
  echo "    WARNING: versions differ. The grafted ghostty helper may not match the"
  echo "    fork's Ghostty. Usually still fine; update the official app if the"
  echo "    terminal CLI helper misbehaves:  brew upgrade --cask cmux"
fi

# 1. Build the Swift app: arm64-only, ad-hoc signed, entitlements dropped (no
#    Apple team/profile), helper stubbed. Deterministic output dir via -derivedDataPath.
echo "==> Building (arm64, ad-hoc, helper stubbed)…"
CMUX_SKIP_ZIG_BUILD=1 xcodebuild \
  -project cmux.xcodeproj -scheme cmux -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  PRODUCT_BUNDLE_IDENTIFIER="$STAGING_BUNDLE_ID" \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_ENTITLEMENTS="" PROVISIONING_PROFILE_SPECIFIER="" DEVELOPMENT_TEAM="" \
  build

APP="$DERIVED/Build/Products/Release/cmux.app"
[[ -d "$APP" ]] || { echo "error: built app not found at $APP" >&2; exit 1; }

# 2. Set the display name (project uses a manual Info.plist, so xcodebuild's
#    INFOPLIST_KEY_* overrides are ignored — set it directly).
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${STAGING_APP_NAME}" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${STAGING_APP_NAME}" "$APP/Contents/Info.plist"

# 3. Graft the real universal ghostty helper + share resources from the official app.
echo "==> Grafting ghostty helper + resources from official app…"
cp -f "$OFFICIAL_APP/Contents/Resources/bin/ghostty" "$APP/Contents/Resources/bin/ghostty"
for d in ghostty terminfo shell-integration; do
  if [[ -d "$OFFICIAL_APP/Contents/Resources/$d" ]]; then
    rm -rf "$APP/Contents/Resources/$d"
    cp -R "$OFFICIAL_APP/Contents/Resources/$d" "$APP/Contents/Resources/$d"
  fi
done

# 4. Ad-hoc re-sign the grafted binary then the whole bundle.
echo "==> Ad-hoc re-signing…"
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/bin/ghostty" >/dev/null 2>&1 || true
codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true
codesign --verify "$APP" >/dev/null 2>&1 && echo "    signature: valid" || echo "    signature: WARNING not valid"

# 5. Quit any running staging instance, install, seed settings once, launch.
echo "==> Installing to ${INSTALL_PATH}…"
osascript -e "tell application id \"${STAGING_BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do pgrep -f "${STAGING_APP_NAME}.app/Contents/MacOS/cmux" >/dev/null 2>&1 || break; sleep 0.3; done
pkill -f "${STAGING_APP_NAME}.app/Contents/MacOS/cmux" 2>/dev/null || true
rm -rf "$INSTALL_PATH"
cp -R "$APP" "$INSTALL_PATH"

if [[ ! -f "$MIGRATED_MARKER" ]]; then
  echo "==> First run: seeding settings once from the official app…"
  mkdir -p "$APP_SUPPORT"
  SRC="$APP_SUPPORT/session-${OFFICIAL_BUNDLE_ID}.json"
  DST="$APP_SUPPORT/session-${STAGING_BUNDLE_ID}.json"
  [[ -f "$SRC" && ! -f "$DST" ]] && cp "$SRC" "$DST" && echo "    seeded workspace layout"
  defaults export "$OFFICIAL_BUNDLE_ID" - 2>/dev/null | defaults import "$STAGING_BUNDLE_ID" - 2>/dev/null \
    && echo "    seeded preferences" || true
  touch "$MIGRATED_MARKER"
fi

echo "==> Installed: $INSTALL_PATH  (fork ${BRANCH} @ ${COMMIT})"
if [[ "$OPEN_AFTER" -eq 1 ]]; then
  open "$INSTALL_PATH"
  echo "==> Launched cmux STAGING."
else
  echo "==> Done (not launched; --no-open)."
fi
