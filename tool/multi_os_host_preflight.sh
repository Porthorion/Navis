#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./tool/multi_os_host_preflight.sh [--auto-fix] [--doctor]

Checks release-host readiness for Flutter multi-OS targets.

Options:
  --auto-fix  Run best-effort brew-based installs on macOS.
  --doctor    Run `flutter doctor -v` at the end.
  -h, --help  Show this help.

This script does not modify git state.
EOF
}

AUTO_FIX=0
RUN_DOCTOR=0

while (($# > 0)); do
  case "$1" in
    --auto-fix)
      AUTO_FIX=1
      ;;
    --doctor)
      RUN_DOCTOR=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[preflight] Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

OS_NAME="$(uname -s)"
FAILURES=0
WARNINGS=0

log_ok() {
  echo "[ok] $1"
}

log_warn() {
  echo "[warn] $1"
  WARNINGS=$((WARNINGS + 1))
}

log_info() {
  echo "[info] $1"
}

log_fail() {
  echo "[fail] $1"
  FAILURES=$((FAILURES + 1))
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

check_cmd() {
  local cmd="$1"
  local label="$2"
  local install_hint="$3"
  if has_cmd "$cmd"; then
    log_ok "$label"
  else
    log_fail "$label missing. Install: $install_hint"
  fi
}

check_flutter_version() {
  if ! has_cmd flutter; then
    log_fail "Flutter missing. Install from https://docs.flutter.dev/get-started/install"
    return
  fi

  local flutter_line flutter_version flutter_channel
  flutter_line="$(flutter --version | sed -n '1p')"
  flutter_version="$(awk '{print $2}' <<<"$flutter_line")"
  flutter_channel="$(awk '{print $5}' <<<"$flutter_line")"
  log_ok "Flutter $flutter_version ($flutter_channel)"
}

macos_auto_fix() {
  if [[ "$AUTO_FIX" -ne 1 ]]; then
    return
  fi
  if [[ "$OS_NAME" != "Darwin" ]]; then
    log_warn "--auto-fix currently supports macOS only."
    return
  fi
  if ! has_cmd brew; then
    log_fail "Homebrew is required for --auto-fix."
    return
  fi

  echo "[preflight] Running macOS auto-fix with Homebrew..."
  brew update
  brew install cocoapods cmake ninja pkg-config openjdk@21 || true
  brew install --cask android-commandlinetools || true
  echo "[preflight] Auto-fix complete. Review Android SDK and Xcode tasks below."
}

print_macos_install_hints() {
  cat <<'EOF'
[hints][macOS]
- Xcode + CLT:
  xcode-select --install
  sudo xcodebuild -runFirstLaunch
  sudo xcodebuild -license accept
- CocoaPods:
  brew install cocoapods
- Build toolchain:
  brew install cmake ninja pkg-config
- Android cmdline tools:
  brew install --cask android-commandlinetools
  export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
  yes | "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" --licenses
  "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" \
    "platform-tools" "platforms;android-36" "build-tools;36.0.0"
EOF
}

print_linux_install_hints() {
  cat <<'EOF'
[hints][Linux]
- sudo apt-get update
- sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev
- Install Android cmdline tools and accept licenses:
  yes | sdkmanager --licenses
EOF
}

print_windows_install_hints() {
  cat <<'EOF'
[hints][Windows]
- winget install --id Git.Git -e
- winget install --id Microsoft.VisualStudio.2022.BuildTools -e
- winget install --id Kitware.CMake -e
- winget install --id Ninja-build.Ninja -e
- winget install --id Google.AndroidStudio -e
- Android licenses:
  %ANDROID_SDK_ROOT%\cmdline-tools\latest\bin\sdkmanager.bat --licenses
EOF
}

echo "[preflight] Host OS: $OS_NAME"

check_flutter_version
check_cmd dart "Dart SDK available" "Included with Flutter"
check_cmd git "Git available" "brew install git / apt-get install git / winget install Git.Git"
check_cmd cmake "CMake available" "brew install cmake / apt-get install cmake / winget install Kitware.CMake"
check_cmd ninja "Ninja available" "brew install ninja / apt-get install ninja-build / winget install Ninja-build.Ninja"

if [[ "$OS_NAME" == "Darwin" ]]; then
  xcode_select_path=""
  if xcode_select_path="$(xcode-select -p 2>/dev/null)"; then
    log_ok "Xcode select path configured: $xcode_select_path"
  else
    log_fail "Xcode Command Line Tools missing. Install: xcode-select --install"
  fi

  if has_cmd xcodebuild; then
    log_ok "xcodebuild available"
  else
    log_fail "xcodebuild missing. Install full Xcode from App Store."
  fi

  if [[ -d "/Applications/Xcode.app" ]]; then
    log_ok "Full Xcode app detected at /Applications/Xcode.app"
  else
    log_fail "Full Xcode app not found at /Applications/Xcode.app."
  fi

  if [[ "$xcode_select_path" == *"/CommandLineTools" ]]; then
    log_fail "xcode-select points to CommandLineTools. Switch after installing full Xcode: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
  fi

  if has_cmd xcrun; then
    sim_runtimes_output="$(xcrun simctl list runtimes 2>/dev/null || true)"
    if [[ -z "${sim_runtimes_output}" ]]; then
      log_warn "Unable to query Simulator runtimes via xcrun simctl."
    elif ! grep -Eq 'iOS|watchOS|tvOS|visionOS' <<<"${sim_runtimes_output}"; then
      log_warn "No Simulator runtimes installed. Non-blocking for macOS-only releases; required for iOS simulator workflows."
      log_info "Install via Xcode > Settings > Platforms, or run: xcodebuild -downloadPlatform iOS"
    else
      log_ok "Xcode Simulator runtimes detected"
    fi
  else
    log_warn "xcrun not found; unable to inspect Simulator runtimes."
  fi

  check_cmd pod "CocoaPods available" "brew install cocoapods"
  check_cmd adb "Android platform-tools available" "Install platform-tools via sdkmanager"

  detected_sdk_root="${ANDROID_SDK_ROOT:-}"
  if [[ -z "$detected_sdk_root" && -d "$HOME/Library/Android/sdk" ]]; then
    detected_sdk_root="$HOME/Library/Android/sdk"
    log_info "ANDROID_SDK_ROOT not exported; auto-detected default SDK path: $detected_sdk_root"
  fi

  if [[ -n "$detected_sdk_root" ]]; then
    log_ok "Android SDK root available: $detected_sdk_root"
  else
    log_warn "Android SDK root not detected; set ANDROID_SDK_ROOT for deterministic sdkmanager usage."
  fi

  print_macos_install_hints
elif [[ "$OS_NAME" == "Linux" ]]; then
  check_cmd pkg-config "pkg-config available" "sudo apt-get install pkg-config"
  print_linux_install_hints
elif [[ "$OS_NAME" == "MINGW64_NT"* || "$OS_NAME" == "MSYS_NT"* || "$OS_NAME" == "CYGWIN_NT"* ]]; then
  print_windows_install_hints
else
  log_warn "Unsupported host OS for detailed checks: $OS_NAME"
fi

macos_auto_fix

if [[ "$RUN_DOCTOR" -eq 1 ]]; then
  if has_cmd flutter; then
    echo "[preflight] Running flutter doctor -v..."
    flutter doctor -v || true
  else
    log_warn "Skipped flutter doctor because Flutter is not installed."
  fi
fi

echo "[preflight] Completed with $FAILURES failure(s), $WARNINGS warning(s)."
if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi
