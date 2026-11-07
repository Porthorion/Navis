# iOS release: TestFlight and the App Store

iOS has two artifacts, and `tool/release.sh` builds both when `ios` is in the
targets:

| Artifact | Built with | Goes to | Update check |
|---|---|---|---|
| Signed App Store IPA (`build/ios/ipa/Navis.ipa`) | `flutter build ipa`, manual signing | App Store Connect with `--ios-upload`; never a release asset | none: the update UI is hidden |
| Unsigned sideload IPA (`navis-<tag>-ios-sideload.ipa`) | `flutter build ios --release --no-codesign --dart-define=NAVIS_IOS_SIDELOAD=true` | R2 and GitHub releases, for AltStore/SideStore users, who sign it with their own Apple ID | yes: shows a notice that links to the GitHub release page |

An ad-hoc IPA installs only on devices registered with the Apple Developer
account, so the App Store IPA is never attached to a release. iOS cannot update
an app by itself, so the sideload build only links to the release page; the
user installs the new IPA through AltStore/SideStore.

## Sideload IPA

- `NAVIS_IOS_SIDELOAD` (`AppConstants.iosSideload`, default `false`) is the only
  thing that turns the update check on for iOS. Only the sideload build gets it
  (`NAVIS_SELF_UPDATE` is not reused: it defaults to true, and dev and simulator
  builds must stay updater-free). The App Store build, which takes
  `DART_DEFINE_ARGS` without it, is checked by `tool/ios_release_test.sh`.
- The sideload app is built first and zipped out of `build/ios/iphoneos` into
  `Payload/Runner.app` (symlinks kept) before the App Store build runs, after
  `build/ios/iphoneos` is cleared, so neither build can pick up the other's
  output. Its `Info.plist` must carry the release version and the pubspec build
  number or the release fails. It is scanned for the plaintext Last.fm key like
  every artifact.
- Stable runs only. A dev tag builds the App Store flavour alone: its update
  notice links to a GitHub release, and GitHub publication is stable-only.
- The manifest key is `iosSideload`; the app verifies it like any asset and
  then opens `https://github.com/Porthorion/Navis/releases/tag/<tag>`
  ([release-r2.md](release-r2.md)).

## App Store and TestFlight

Team ID `BFBNSCVKXH` (a public identifier) is set as `DEVELOPMENT_TEAM` on the
Runner target. Debug and Profile sign automatically; the Runner Release
configuration signs manually with the `Apple Distribution` certificate and the
App Store provisioning profile `Navis App Store`, because automatic signing
archives with a development profile, which needs a registered device. Release
is therefore for `flutter build ipa` only: a Release app cannot be installed on
a phone directly, so use Profile or Debug on a device. The bundle ID is
`com.navis.app.navis`, the same as Android and macOS.

## One-time setup

1. Create an Apple Distribution certificate (Xcode › Settings › Accounts ›
   Manage Certificates, or the developer portal) so its identity is in the
   login keychain. Then, in Certificates, Identifiers & Profiles › Profiles,
   create a Distribution › App Store Connect profile for `com.navis.app.navis`
   with that certificate, named exactly `Navis App Store`, and copy it to
   `~/Library/Developer/Xcode/UserData/Provisioning Profiles/<UUID>.mobileprovision`
   (double-clicking does not always install it). No certificate or profile is
   stored in the repository. Both expire after a year: renew the certificate,
   regenerate the profile under the same name and install it again.
2. Register the app ID `com.navis.app.navis` (Certificates, Identifiers &
   Profiles) and create the App Store Connect record named "Navis" with that
   bundle ID.
3. In App Store Connect › Users and Access › Integrations › App Store Connect
   API, create a team key with the App Manager role. Download the `.p8` once
   and save it as
   `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` (mode 600). Note the
   Key ID and the Issuer ID.
4. Put the identifiers in `tool/release.env` (git-ignored, mode 600) or the
   shell environment:

   ```bash
   ASC_KEY_ID="<key-id>"
   ASC_ISSUER_ID="<issuer-id>"
   # Optional: keep the key file somewhere else.
   # ASC_KEY_PATH="/absolute/path/AuthKey_<key-id>.p8"
   ```

   The scripts read these values but never print them. See
   [release-secrets.md](release-secrets.md).

## Build and upload

```bash
./tool/release.sh v1.5.2 --targets=ios --build-only --ios-upload
```

- `--ios-upload` needs `ios` in `--targets`, the stable channel (a dev tag is
  not a valid App Store version), `ASC_KEY_ID`, `ASC_ISSUER_ID` and the key
  file. `release.sh` checks all of that before any build and names the missing
  variable without printing values. It cannot be combined with
  `--publish-from`.
- The build is `flutter build ipa --release
  --export-options-plist=ios/ExportOptions.plist`: method `app-store-connect`,
  manual signing with the `Navis App Store` profile, symbols uploaded. It
  runs with `/usr/bin` first on `PATH` because the export fails ("Copy
  failed") with a MacPorts or Homebrew `rsync` 3.x. `build/ios/ipa` is deleted first so a
  stale IPA is never uploaded. The IPA is scanned for the plaintext Last.fm key
  like every other artifact.
- The upload is `xcrun altool --upload-app -t ios -f <ipa> --api-key ...
  --api-issuer ... --p8-file-path <key file>`; the Xcode 27 `altool` accepts a
  direct key path, so `ASC_KEY_PATH` works.
- A stable iOS-only run publishes the sideload IPA; an iOS-only dev run publishes
  nothing, so it needs `--build-only` (an upload is not a publication). The App
  Store IPA never becomes a release asset. The upload runs after every target
  has built, before any tag or publication, so a later build failure never
  leaves a rerun re-uploading a build number App Store Connect already holds.
- Trade-off: in a multi-target release a publish failure after the upload
  leaves a TestFlight build with no matching release. Re-running builds again
  and uploads with a new build number, which the allocator assigns
  automatically, so nothing needs fixing by hand.
- `--publish-from` accepts only the exact sideload name
  (`<prefix>-<tag>-ios-sideload.ipa`). Staged bundles made earlier have no IPA
  and publish as before; one that holds any other `.ipa` is rejected, so restage
  it with `--build-only`.
- Without `--ios-upload` the IPA is only built; the path is printed.

## Build numbers

TestFlight rejects an upload whose `CFBundleVersion` is not higher than every
earlier upload of the same `CFBundleShortVersionString`, and the pubspec build
number (`1.5.2+10502`) never changes within a version. So the iOS build passes
`--build-number` from `tool/dev_build_number.py`, the monotonic per-host
allocator that Android dev builds already use: every build gets a higher number
(about 37 million in 2026) and several uploads of 1.5.2 are accepted. The
number differs from the Android `versionCode`; only the iOS train cares. Always
build iOS on the release Mac: the allocator's state is
`~/.cache/navis/dev-releases` on that host, so a second host could allocate a
lower number than one already uploaded.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `false` in `ios/Runner/Info.plist`: Navis
uses only the platform's HTTPS and keychain, so App Store Connect does not ask
the export-compliance question per build.

## TestFlight internal testing

After processing (minutes, plus an email), open App Store Connect › Navis ›
TestFlight, add the build to an internal group of up to 100 team members
(App Store Connect users) and install through the TestFlight app. Internal
builds need no beta review. External testers and the App Store need the review
and the metadata below.

## App Store privacy answers (for the owner to confirm in App Store Connect)

Grounded in the code at this commit. Navis has no analytics, advertising,
crash-reporting or tracking SDK (`pubspec.yaml` lists none; `lib/main.dart`
only logs locally), and `ios/Runner/PrivacyInfo.xcprivacy` declares
`NSPrivacyTracking` false, no tracking domains and no collected data, plus the
required-reason APIs disk space (`E174.1`) and file timestamps (`C617.1`).

Network destinations (user-controlled in Settings › Integrations, with a
master "Online services" switch). Deezer, Last.fm, LRCLIB and the artwork hosts
are on by default; ListenBrainz does nothing until the user enters and
validates a token, and AutoEQ is contacted only when the user asks for a
headphone profile:

| Destination | What is sent | iOS |
|---|---|---|
| The user's own Subsonic/OpenSubsonic server | credentials, library requests, scrobbles | always |
| `api.deezer.com` | artist and album names, Search text for ranking | yes |
| Deezer image servers (`dzcdn.net`, `deezer.com`) | the image request | yes |
| `ws.audioscrobbler.com` (Last.fm) | artist and track names for similar tracks, similar artists and top songs, plus a chart top-artists call; no scrobbling, no account | yes |
| `api.listenbrainz.org` | listens and likes, only after the user enters their own token | yes |
| `lrclib.net` | track, artist, album and duration for lyrics | yes |
| `raw.githubusercontent.com`, `api.github.com` | AutoEQ catalogue request | yes |
| `coverartarchive.org` | the cover image request | yes |
| Radio streams and artwork hosts the server links to | the request itself | yes |
| `downloads.porthorion.com` (update check) | none beyond the request | sideload build only; hidden in App Store and TestFlight builds |

Recommended answers:

- **Data used to track you:** none. No tracking, no data broker sharing.
- **Privacy policy URL:** required. Use `https://navis.porthorion.com/privacy/app`
  (`AppConstants.privacyPolicyUrl`), after checking it names the services above.
- **Data collected by the developer:** none. The developer operates no server,
  receives nothing, and the app keeps credentials in the keychain on the device.
  Choose "Data Not Collected".
- **Judgement call to confirm:** requests to Deezer, Last.fm, LRCLIB, GitHub
  and ListenBrainz go straight from the device to those services, which Apple
  can read as third-party collection. They carry music metadata and, for
  ListenBrainz, the user's own listening history under the user's own account.
  If the owner prefers the conservative reading, declare Usage Data › Product
  Interaction (listening history to ListenBrainz) and Search History (Search
  text sent to Deezer), both "not linked to the user" and "not used for
  tracking", purpose App Functionality.
- **Account sign-in:** the server account is the user's own, so no in-app
  account creation exists and no account-deletion flow is required.
- **Age rating and content rights:** the app plays the user's own media; answer
  the questionnaire accordingly.

## Post-merge runtime check

No App Store Connect key existed when this path was written, so the signed
build and upload are unexercised. Once the key exists, run the command above on
the release Mac, confirm the build processes in App Store Connect and that
TestFlight installs it. Fix any signing prompt (missing distribution
certificate, no provisioning access) from Xcode first.
