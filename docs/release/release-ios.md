# iOS release: TestFlight and the App Store

iOS ships through App Store Connect only. An ad-hoc IPA installs only on
devices registered with the Apple Developer account, and iOS has no in-app
updater, so `tool/release.sh` no longer attaches an IPA to R2 or GitHub
releases. It builds a signed App Store IPA, leaves it in `build/ios/ipa/` and,
with `--ios-upload`, uploads it to App Store Connect, where it appears in
TestFlight after processing.

Team ID `BFBNSCVKXH` (a public identifier) is set as `DEVELOPMENT_TEAM` on the
Runner target, with automatic signing. The bundle ID is `com.navis.app.navis`,
the same as Android and macOS.

## One-time setup

1. Sign Xcode in to the Apple ID of the paid Apple Developer Program
   (Xcode › Settings › Accounts). Flutter passes `-allowProvisioningUpdates` to
   the archive and export steps, so automatic signing can create the Apple
   Distribution certificate and the App Store profile on the first release
   build; no certificate is stored in the repository. If it cannot, create the
   certificate under Manage Certificates in that Accounts pane first.
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
  automatic signing, symbols uploaded. `build/ios/ipa` is deleted first so a
  stale IPA is never uploaded. The IPA is scanned for the plaintext Last.fm key
  like every other artifact.
- The upload is `xcrun altool --upload-app -t ios -f <ipa> --api-key ...
  --api-issuer ... --p8-file-path <key file>`; the Xcode 27 `altool` accepts a
  direct key path, so `ASC_KEY_PATH` works.
- An iOS-only run publishes nothing, so it needs `--build-only` (an upload is not
  a publication). Combined with other targets in a normal release, the IPA is
  built while the other assets are published as before; it never becomes a
  release asset. The upload runs after every target has built, before any tag
  or publication, so a later build failure never leaves a rerun re-uploading a
  build number App Store Connect already holds.
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

Network destinations (all user-controlled in Settings › Integrations, all on by
default, with a master "Online services" switch):

| Destination | What is sent | iOS |
|---|---|---|
| The user's own Subsonic/OpenSubsonic server | credentials, library requests, scrobbles | always |
| `api.deezer.com` | artist and album names, Search text for ranking | yes |
| `ws.audioscrobbler.com` (Last.fm) | artist and track names for similar tracks and top songs; no scrobbling, no account | yes |
| `api.listenbrainz.org` | listens and likes, only after the user enters their own token | yes |
| `lrclib.net` | track, artist, album and duration for lyrics | yes |
| `raw.githubusercontent.com`, `api.github.com` | AutoEQ catalogue request | yes |
| Radio streams and artwork hosts the server links to | the request itself | yes |
| `downloads.porthorion.com` (update check) | none beyond the request | hidden on iOS |

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
