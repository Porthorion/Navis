#!/usr/bin/env bash
set -euo pipefail

navis_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
navis_fixture="$(mktemp -d)"
trap 'rm -rf "${navis_fixture}"' EXIT
mkdir -p "${navis_fixture}/tool" "${navis_fixture}/android/gradle/wrapper" \
  "${navis_fixture}/sdk space/bin/cache/artifacts/gradle_wrapper/gradle/wrapper" \
  "${navis_fixture}/bin"
cp "${navis_root}/tool/android_repeat_native_test.sh" "${navis_fixture}/tool/"
export NAVIS_FLUTTER_SDK="${navis_fixture}/sdk space"
export ANDROID_STUDIO_JDK="${navis_fixture}/jdk"
export NAVIS_FIXTURE_ARGS="${navis_fixture}/args"
export NAVIS_FIXTURE_TIMEOUT="${navis_fixture}/timeout"
export NAVIS_FIXTURE_JDK="${navis_fixture}/jdk-used"
export PATH="${navis_fixture}/bin:${PATH}"
cat >"${navis_fixture}/bin/timeout" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${NAVIS_FIXTURE_TIMEOUT}"
[[ "$1" == --kill-after=10s && "$2" == 10m ]] || exit 91
if [[ "${NAVIS_FIXTURE_TIMEOUT_EXIT:-0}" != 0 ]]; then
  exit "${NAVIS_FIXTURE_TIMEOUT_EXIT}"
fi
shift 2
exec "$@"
STUB
cat >"${NAVIS_FLUTTER_SDK}/bin/cache/artifacts/gradle_wrapper/gradlew" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${NAVIS_FIXTURE_ARGS}"
printf '%s' "${JAVA_HOME:-}" >"${NAVIS_FIXTURE_JDK}"
[[ "${NAVIS_SELF_UPDATE:-}" == true ]] || exit 92
exit "${NAVIS_FIXTURE_EXIT:-0}"
STUB
printf 'fixture wrapper\n' >"${NAVIS_FLUTTER_SDK}/bin/cache/artifacts/gradle_wrapper/gradle/wrapper/gradle-wrapper.jar"
chmod +x "${navis_fixture}/bin/timeout" \
  "${NAVIS_FLUTTER_SDK}/bin/cache/artifacts/gradle_wrapper/gradlew"

# Start without ignored wrapper files, as in a clean CI checkout.
NAVIS_SELF_UPDATE=false "${navis_fixture}/tool/android_repeat_native_test.sh"
test -f "${navis_fixture}/android/gradle/wrapper/gradle-wrapper.jar"
test "$(cat "${NAVIS_FIXTURE_JDK}")" == "${ANDROID_STUDIO_JDK}"
for navis_arg in ':app:testSideloadDebugUnitTest' '--tests' '*JustAudioRepeat*Test' \
  '--no-daemon' '--max-workers=1' '-Pkotlin.compiler.execution.strategy=in-process' \
  '-Dorg.gradle.jvmargs=-Xmx2g -XX:MaxMetaspaceSize=768m -XX:ReservedCodeCacheSize=256m'; do
  grep -Fxq -- "${navis_arg}" "${NAVIS_FIXTURE_ARGS}"
done
for navis_status in 37 124; do
  set +e
  NAVIS_FIXTURE_EXIT="${navis_status}" "${navis_fixture}/tool/android_repeat_native_test.sh"
  navis_actual=$?
  set -e
  test "${navis_actual}" -eq "${navis_status}"
done
set +e
NAVIS_FIXTURE_TIMEOUT_EXIT=124 "${navis_fixture}/tool/android_repeat_native_test.sh"
navis_actual=$?
set -e
test "${navis_actual}" -eq 124

grep -Fq 'run_step "Android repeat bridge JVM" ./tool/android_repeat_native_test.sh' "${navis_root}/tool/check.sh"
grep -Fq -- '- run: ./tool/android_repeat_native_test.sh' "${navis_root}/.github/workflows/ci.yml"
grep -Fq 'needs: [static, test, native]' "${navis_root}/.github/workflows/ci.yml"
grep -Fq 'needs.native.result' "${navis_root}/.github/workflows/ci.yml"
echo 'Android repeat runner: wrapper, bounds, test selection, failure propagation and gate wiring passed.'
