# Troubleshooting

## Tests appear to hang or fail unexpectedly

Check temp space first:

```bash
df -h /tmp
```

If full, clear temporary Flutter artifacts and rerun checks:

```bash
rm -rf /tmp/flutter_tools.* /tmp/dart_test* /tmp/flutter_test*
./tool/check.sh
```

## Android SDK not found

Symptom from `flutter doctor -v`:
- `Unable to locate Android SDK`

Fix:
1. Install Android Studio.
2. Install Android SDK command-line tools and platform SDK 35.
3. Configure Flutter SDK path:

```bash
flutter config --android-sdk <path-to-sdk>
flutter doctor --android-licenses
flutter doctor -v
```

## Linux desktop build fails with missing C++ headers

If you use Linux for local startup validation, install required toolchain packages:

```bash
sudo apt-get install -y clang cmake ninja-build libgtk-3-dev g++ build-essential
```

Rebuild from clean state:

```bash
rm -rf build/linux
flutter run -d linux
```

## Generated files drift in CI

Always run generation before commit:

```bash
dart run build_runner build --delete-conflicting-outputs
```

Then verify no diff:

```bash
git diff --exit-code
```
