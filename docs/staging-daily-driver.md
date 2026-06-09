# Personal "cmux STAGING" daily driver (fork-only)

> **Fork-only doc.** This file exists only on `bcharleson/cmux`, not upstream
> (`manaflow-ai/cmux`). It documents the personal daily-driver setup. Keep it out
> of any PR you open against upstream.

## The three tiers

| Tier | App | Bundle ID | Source | How you get it |
|------|-----|-----------|--------|----------------|
| **stable** | `cmux` | `com.cmuxterm.app` | official manaflow release | `brew install --cask cmux` |
| **staging** | `cmux STAGING` | `com.cmuxterm.app.staging` | this fork's `main` | `./scripts/build-staging-local.sh` |
| **dev** | `cmux DEV` | `com.cmuxterm.app.debug` | feature branches | Xcode run / `reloads.sh` |

All three coexist in `/Applications` because macOS keys app identity (Dock icon,
saved windows, UserDefaults) off the **bundle ID**, not the name. Shortcuts in
`~/.config/cmux/cmux.json` are path-keyed and shared live across all three;
window layout (`session-<bundle-id>.json`) and toggles/theme (`<bundle-id>` plist)
are bundle-id-isolated.

`staging` is the daily driver, built from `main`, which is the fork's integration
line: upstream + your shipped features. `stable` (official) is just consumed via
brew — there is no branch to maintain for it.

## Rebuild the daily driver (one command)

```bash
cd ~/Developer/cmux
git checkout main          # or your staging line
# (optional) pull your fork / merge upstream first:
#   git pull && git merge upstream/main
./scripts/build-staging-local.sh
```

This builds from whatever branch is checked out, installs to
`/Applications/cmux STAGING.app`, seeds settings once from the official app, and
launches it. Use `--no-open` to skip launching.

## Why this Mac needs a special build (the zig / SDK constraint)

The straightforward `promote-personal-release.sh` does **not** work on this
machine. Two hard environment facts:

1. **Signing** — the Release entitlements hardcode manaflow's Apple team
   (`7WLXT3NR37`) and a team-bound `keychain-access-groups` entitlement. We don't
   have that team, so the build is **ad-hoc signed** with entitlements dropped
   (`CODE_SIGN_IDENTITY="-"`, `CODE_SIGN_ENTITLEMENTS=""`). No Apple Developer ID
   needed — this is personal/local use only.

2. **Ghostty CLI helper can't be compiled here** — Ghostty's `build.zig` requires
   **zig 0.15.2 exactly**, but this Mac has only **Xcode-beta / the macOS 26 SDK**,
   which zig 0.15.2 cannot link against (`build_zcu.o` fails to link libSystem),
   and zig 0.16 can't build Ghostty's `build.zig`. So `build-staging-local.sh`:
   - builds the Swift app with the helper **stubbed** (`CMUX_SKIP_ZIG_BUILD=1`),
   - then **grafts** the real universal `ghostty` helper + `terminfo` /
     `shell-integration` resources out of the installed official `cmux.app`
     (same cmux version), and ad-hoc re-signs.

   cmux's in-app terminal renders via the prebuilt **`GhosttyKit.xcframework`**
   compiled into the Swift app, so the grafted CLI helper only covers auxiliary
   `ghostty` command-line features — the terminal itself is unaffected.

### The clean long-term fix
Install a **stable Xcode** (older macOS SDK). zig 0.15.2 links against it
natively, so the helper compiles from source and the graft/stub workaround
becomes unnecessary — then `promote-personal-release.sh` works as designed and
the build can be universal again.

## Other Macs / sharing the fork
Because the staging build is ad-hoc signed (no notarization), distributing the
`.app`/DMG to another Mac needs a one-time Gatekeeper bypass:
`xattr -dr com.apple.quarantine "/Applications/cmux STAGING.app"`. A CI workflow
on `bcharleson/cmux` can build + publish this arm64 DMG to your GitHub releases.
No paid Apple Developer Program required for personal use.

## Build details (what the script pins)
- `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` — arm64-only (your hardware). This is why the
  staging app is ~half the size of the universal official app; it's a feature.
- `PRODUCT_BUNDLE_IDENTIFIER=com.cmuxterm.app.staging` — coexistence.
- Display name set to `cmux STAGING` via PlistBuddy (the project uses a manual
  `Info.plist`, so xcodebuild's `INFOPLIST_KEY_*` overrides are ignored).
- Output dir pinned via `-derivedDataPath ~/.cache/cmux-staging-build`.
