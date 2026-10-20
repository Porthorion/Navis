#!/usr/bin/env bash
set -euo pipefail

navis_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
navis_jdk="${ANDROID_STUDIO_JDK:-${JAVA_HOME:-${HOME}/android-studio/jbr}}"
if command -v javac >/dev/null 2>&1; then
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
  "${navis_source}/test/java/com/ryanheise/just_audio/ProgressiveLoadRetryTest.java"
"${navis_java}" -cp "${navis_classes}" com.ryanheise.just_audio.EqualizerDspTest
"${navis_java}" -cp "${navis_classes}" com.ryanheise.just_audio.ProgressiveLoadRetryTest
