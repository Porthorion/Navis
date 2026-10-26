#!/usr/bin/env bash
# Host JVM fixtures: no APK installation, device or emulator.
set -euo pipefail

navis_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
navis_flutter_sdk="${NAVIS_FLUTTER_SDK:-$(python3 -c 'import pathlib, shutil; print(pathlib.Path(shutil.which("flutter")).resolve().parents[1])')}"
navis_wrapper="${navis_flutter_sdk}/bin/cache/artifacts/gradle_wrapper"

# Flutter generates these ignored files during builds; CI unit tests need them too.
if [[ ! -f "${navis_root}/android/gradlew" ]]; then
  cp "${navis_wrapper}/gradlew" "${navis_root}/android/gradlew"
  chmod +x "${navis_root}/android/gradlew"
fi
if [[ ! -f "${navis_root}/android/gradle/wrapper/gradle-wrapper.jar" ]]; then
  cp "${navis_wrapper}/gradle/wrapper/gradle-wrapper.jar" "${navis_root}/android/gradle/wrapper/gradle-wrapper.jar"
fi

if [[ -n "${ANDROID_STUDIO_JDK:-}" ]]; then
  export JAVA_HOME="${ANDROID_STUDIO_JDK}"
elif ! command -v java >/dev/null 2>&1 && [[ -x "${HOME}/android-studio/jbr/bin/java" ]]; then
  export JAVA_HOME="${HOME}/android-studio/jbr"
fi
export NAVIS_SELF_UPDATE=true
cd "${navis_root}/android"
exec timeout --kill-after=10s 10m ./gradlew \
  :app:testSideloadDebugUnitTest --tests '*JustAudioRepeat*Test' \
  --no-daemon --max-workers=1 --console=plain \
  '-Dorg.gradle.jvmargs=-Xmx2g -XX:MaxMetaspaceSize=768m -XX:ReservedCodeCacheSize=256m' \
  -Pkotlin.compiler.execution.strategy=in-process
