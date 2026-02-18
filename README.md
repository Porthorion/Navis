# Navis

A music player for [Navidrome](https://www.navidrome.org/) (and other Subsonic-compatible servers), built with Flutter. Targets Android and iOS.

## Status

In active development. See [PROGRESS.md](PROGRESS.md) for current status and [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md) for the full roadmap.

## Planned Features

- Stream your entire music library from a Navidrome server
- Gapless playback with background audio and lock screen controls
- Synced and unsynced lyrics
- Offline mode with smart caching (automatic rolling cache + manual pins)
- Download queue with quality selection
- Full playlist management
- Material 3 theming (light, dark, OLED black, dynamic colors)
- In-app update checking via Forgejo releases

## Tech Stack

Flutter, Riverpod, drift (SQLite), just_audio, audio_service, Dio, freezed, go_router, flex_color_scheme.

Stack validation status: reviewed against current Flutter/package guidance on 2026-02-18.  
See the validation notes and sources in [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md#stack-validation-2026-02-18).

## Build

```
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

## License

[GPL-3.0](LICENSE)
