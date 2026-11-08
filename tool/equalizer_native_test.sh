#!/usr/bin/env bash
set -euo pipefail

navis_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
navis_studio_jdk="${HOME}/android-studio/jbr"
[[ "$(uname -s)" != Darwin ]] || navis_studio_jdk='/Applications/Android Studio.app/Contents/jbr/Contents/Home'
# Darwin (iOS) equalizer DSP: plain C11, so any host C compiler runs it.
navis_darwin_source="${navis_root}/third_party/just_audio/darwin"
if navis_cc="$(command -v cc || command -v gcc || command -v clang)"; then
  navis_c_out="$(mktemp -d)"
  # Memory errors in the realtime code must fail CI: use ASan/UBSan when the compiler has them.
  navis_c_sanitize=()
  printf 'int main(void){return 0;}\n' > "${navis_c_out}/probe.c"
  if "${navis_cc}" -fsanitize=address,undefined "${navis_c_out}/probe.c" -o "${navis_c_out}/probe" >/dev/null 2>&1 \
      && "${navis_c_out}/probe" >/dev/null 2>&1; then
    navis_c_sanitize=(-fsanitize=address,undefined -fno-omit-frame-pointer)
  elif [[ -n "${CI:-}" ]]; then
    echo 'ERROR: CI needs a compiler with working ASan/UBSan for the Darwin DSP test.' >&2
    exit 1
  else
    echo 'NOTE: this compiler lacks working ASan/UBSan; running the Darwin DSP test unsanitized.' >&2
  fi
  "${navis_cc}" -std=c11 -O1 -g ${navis_c_sanitize[@]+"${navis_c_sanitize[@]}"} -Wall -Wextra -Werror -pthread -D_POSIX_C_SOURCE=200809L \
    "${navis_darwin_source}/test/navis_equalizer_dsp_test.c" \
    "${navis_darwin_source}/just_audio/Sources/just_audio/NavisEqualizerDsp.c" \
    -lm -o "${navis_c_out}/navis_equalizer_dsp_test"
  "${navis_c_out}/navis_equalizer_dsp_test"
  rm -rf "${navis_c_out}"
else
  echo 'SKIPPED: Darwin equalizer DSP test needs a C compiler (cc, gcc or clang).' >&2
fi
navis_jdk="${ANDROID_STUDIO_JDK:-${JAVA_HOME:-${navis_studio_jdk}}}"
# Probe that javac runs: macOS ships a /usr/bin/javac stub that fails without a JDK.
if javac -version >/dev/null 2>&1; then
  navis_javac="$(command -v javac)"
  navis_java="$(command -v java)"
else
  navis_javac="${navis_jdk}/bin/javac"
  navis_java="${navis_jdk}/bin/java"
fi
if [[ ! -x "${navis_javac}" || ! -x "${navis_java}" ]]; then
  echo 'EQ fixtures require a JDK. Set ANDROID_STUDIO_JDK to its directory.' >&2
  exit 1
fi
navis_classes="$(mktemp -d)"
trap 'rm -rf "${navis_classes}"' EXIT
navis_source="${navis_root}/third_party/just_audio/android/src"
"${navis_javac}" -d "${navis_classes}" \
  "${navis_source}/main/java/com/ryanheise/just_audio/EqualizerDsp.java" \
  "${navis_source}/test/java/com/ryanheise/just_audio/EqualizerDspTest.java" \
  "${navis_source}/main/java/com/ryanheise/just_audio/ProgressiveLoadRetry.java" \
  "${navis_source}/test/java/com/ryanheise/just_audio/ProgressiveLoadRetryTest.java" \
  "${navis_source}/main/java/com/ryanheise/just_audio/ProgressiveRepeat.java" \
  "${navis_source}/test/java/com/ryanheise/just_audio/ProgressiveRepeatTest.java"
"${navis_java}" -cp "${navis_classes}" com.ryanheise.just_audio.EqualizerDspTest
"${navis_java}" -cp "${navis_classes}" com.ryanheise.just_audio.ProgressiveLoadRetryTest
"${navis_java}" -cp "${navis_classes}" com.ryanheise.just_audio.ProgressiveRepeatTest
