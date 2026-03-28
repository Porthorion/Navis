# Releasing Navis for macOS

Navis for macOS is distributed as a `.app` bundle inside a `.zip` archive. Users download
the zip, extract it, and drag the app to `/Applications`. The built-in auto-updater handles
all subsequent updates.

---

## Platform constraint

macOS builds require a macOS host running Xcode. There is no cross-compilation path from
Linux or Windows and no `--macos-ssh` flag. Run `tool/release.sh` directly on the Mac.

---

## Prerequisites

### 1. Flutter SDK

```bash
flutter --version          # Flutter 3.x stable
flutter doctor -v
```

### 2. Xcode

Install from the Mac App Store (Xcode ≥ 15 recommended). Complete first-launch setup:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

### 3. CocoaPods

```bash
brew install cocoapods
```

### 4. Run the preflight script

```bash
./tool/multi_os_host_preflight.sh --doctor
```

Resolve any failures before building.

### 5. Forgejo token

Create `tool/release.env` (git-ignored):

```bash
FORGEJO_URL="https://git.porthorion.com"
FORGEJO_REPO="khalifa/Navis"
FORGEJO_TOKEN="<personal-access-token-with-write:release>"
```

---

## Code Signing

### Why signing matters

macOS Gatekeeper blocks apps from unrecognized developers. Without a valid Developer ID
signature, users must right-click → Open and dismiss a warning on every launch. Unsigned
apps also block the auto-updater on some macOS configurations.

### Developer ID Application certificate (required for public distribution)

Enroll in the Apple Developer Program ($99/year), then create a **Developer ID Application**
certificate in Xcode or Keychain Access.

Find your signing identity:

```bash
security find-identity -v -p codesigning
# Look for: Developer ID Application: <Team Name> (<TEAMID>)
```

Add to `tool/release.env`:

```bash
MACOS_SIGN_IDENTITY="Developer ID Application: Your Team Name (XXXXXXXXXXX)"
```

---

## Notarization

### Why notarization is required

macOS 10.15+ requires any app distributed outside the App Store to be notarized by Apple.
Without notarization, Gatekeeper shows a hard block ("can't be opened because Apple cannot
check it for malicious software") with no safe override for standard users.

### Steps

#### 1. Create an app-specific password

Go to [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security →
App-Specific Passwords → Generate a password for "Navis-notarize".

#### 2. Store credentials in Keychain

Run once on the release machine:

```bash
xcrun notarytool store-credentials navis-notary-profile \
  --apple-id "you@example.com" \
  --team-id "XXXXXXXXXXX" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

#### 3. Add to `tool/release.env`

```bash
MACOS_NOTARY_PROFILE="navis-notary-profile"
```

#### 4. Verify after notarization

```bash
spctl --assess --type execute --verbose=4 Navis.app
# Expected output: "accepted"
```

---

## Using the Release Script

### Development / internal build (no signing)

Only for testing internally. Will trigger Gatekeeper warnings for any external user.

```bash
./tool/release.sh v0.x.y --targets=macos
```

### Production release (with notarization)

```bash
./tool/release.sh v0.x.y --targets=macos --macos-notarize
```

### macOS + Android in one pass

```bash
./tool/release.sh v0.x.y --targets=android,macos --macos-notarize
```

### Dev channel

```bash
./tool/release.sh v0.x.y --channel=dev --targets=macos
```

Asset naming: `navis-dev-v0.x.y-macos.zip`

### What the script does

1. Runs `./tool/check.sh` (format, analyze, test) — skip with `--skip-checks`.
2. Calls `flutter build macos --release`.
3. **With `--macos-notarize`:** calls `tool/macos_notarize.sh` which signs → notarizes →
   staples → packages with `ditto`.
4. **Without `--macos-notarize`:** packages with `ditto -c -k --keepParent`.
5. Bumps `pubspec.yaml`, commits, tags, pushes to Forgejo.
6. Creates a Forgejo release and uploads `navis-v0.x.y-macos.zip`.

---

## Why `ditto`, not `zip`

macOS app bundles contain symlinks and extended attributes (including the code signature
itself). The standard `zip` command on macOS strips these, invalidating the code signature.
`ditto -c -k --keepParent` preserves them correctly. Always use `ditto` to package `.app`
bundles.

---

## Manual Packaging (without the release script)

```bash
flutter build macos --release --dart-define=NAVIS_UPDATE_CHANNEL=stable

APP_PATH="build/macos/Build/Products/Release/Navis.app"
ditto -c -k --keepParent "${APP_PATH}" navis-v0.x.y-macos.zip
```

---

## User Installation

1. Download `navis-v0.x.y-macos.zip` from the releases page.
2. Double-click the zip to extract `Navis.app`.
3. Drag `Navis.app` to `/Applications`.
4. If the build is notarized: double-click to launch. No warning.
5. If not notarized: right-click → Open → Open (once). Subsequent launches are normal.

Once installed, the auto-updater handles all future updates.

---

## Auto-Updater Behavior

When a new version is detected:

1. **Write-access check:** verifies that `/Applications` (or wherever the `.app` lives) is
   writable. If not, shows "Download Manually" and links to the release page.
2. Downloads `navis-vX.Y.Z-macos.zip` to the system temp directory.
3. Extracts using `ditto -xk`, which preserves the code signature.
4. Resolves the current `.app` bundle path by walking up from the running executable.
5. Writes a bash updater script to temp and launches it detached, then exits.

The updater script:
- Waits 2 seconds for the app to exit.
- Backs up the current `.app` as `.app.backup`.
- Moves the new `.app` into place.
- Launches using `open Navis.app`.
- Removes the backup and self-deletes.
- If moving the new version fails, **automatically restores the backup** so the user's app
  remains functional.

---

## Troubleshooting

### Build fails: `Pod install failed` / CocoaPods errors

```bash
brew install cocoapods
cd macos && pod install --repo-update
```

### Notarization fails: `The team ID in the signing certificate does not match`

The `MACOS_SIGN_IDENTITY` string must exactly match the certificate in Keychain, including
the team ID in parentheses. Run `security find-identity -v -p codesigning` to see the
exact string.

### Notarization fails: `Unable to find keychain profile`

The profile name must match exactly what was stored:

```bash
xcrun notarytool history --keychain-profile navis-notary-profile
```

### Users see "damaged and can't be opened" even after notarization

This usually means the archive was created with `zip` instead of `ditto`, stripping the
signature. Recreate the zip with `ditto -c -k --keepParent Navis.app navis.zip`.

### Auto-updater uses `ditto` to extract — what if `ditto` is not available?

`ditto` ships with macOS and is located at `/usr/bin/ditto`. It is always present.

### `xcrun notarytool` not found

Requires Xcode command-line tools:

```bash
xcode-select --install
```
