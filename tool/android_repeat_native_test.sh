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
timeout --kill-after=10s 10m ./gradlew \
  :app:testSideloadDebugUnitTest --tests '*JustAudioRepeat*Test' \
  --no-daemon --max-workers=1 --console=plain \
  '-Dorg.gradle.jvmargs=-Xmx2g -XX:MaxMetaspaceSize=768m -XX:ReservedCodeCacheSize=256m' \
  -Pkotlin.compiler.execution.strategy=in-process

python3 - "${navis_root}/build/app/test-results/testSideloadDebugUnitTest" <<'PYTHON'
import pathlib
import sys
import xml.etree.ElementTree as ET

total = 0
for name in ("JustAudioRepeatBoundaryTest", "JustAudioRepeatCallbackTest"):
    suite = ET.parse(pathlib.Path(sys.argv[1]) / f"TEST-com.navis.app.navis.{name}.xml").getroot()
    executed = int(suite.attrib["tests"]) - int(suite.get("skipped", "0"))
    if executed <= 0 or int(suite.get("failures", "0")) or int(suite.get("errors", "0")):
        sys.exit(f"Android repeat bridge: {name} must execute tests with no failures.")
    total += executed
print(f"Android repeat bridge: {total} tests, 0 failures.")
PYTHON
