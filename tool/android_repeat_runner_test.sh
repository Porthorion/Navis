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
mkdir -p ../build/app/test-results/testSideloadDebugUnitTest
for suite in JustAudioRepeatBoundaryTest JustAudioRepeatCallbackTest; do
  printf '<testsuite tests="%s" failures="0" errors="0" skipped="0"/>\n' "${NAVIS_FIXTURE_TESTS:-1}" >"../build/app/test-results/testSideloadDebugUnitTest/TEST-com.navis.app.navis.${suite}.xml"
done
exit "${NAVIS_FIXTURE_EXIT:-0}"
STUB
printf 'fixture wrapper\n' >"${NAVIS_FLUTTER_SDK}/bin/cache/artifacts/gradle_wrapper/gradle/wrapper/gradle-wrapper.jar"
chmod +x "${navis_fixture}/bin/timeout" \
  "${NAVIS_FLUTTER_SDK}/bin/cache/artifacts/gradle_wrapper/gradlew"

# Start without ignored wrapper files, as in a clean CI checkout.
NAVIS_SELF_UPDATE=false "${navis_fixture}/tool/android_repeat_native_test.sh" >"${navis_fixture}/output"
grep -Fxq 'Android repeat bridge: 2 tests, 0 failures.' "${navis_fixture}/output"
set +e
NAVIS_FIXTURE_TESTS=0 "${navis_fixture}/tool/android_repeat_native_test.sh" >"${navis_fixture}/zero-output" 2>&1
navis_actual=$?
set -e
test "${navis_actual}" -ne 0
grep -Fq 'must execute tests with no failures' "${navis_fixture}/zero-output"
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

python3 - "${navis_root}" <<'PYTHON'
import copy
import pathlib
import shlex
import sys
import yaml

root = pathlib.Path(sys.argv[1])
check = (root / "tool/check.sh").read_text()
workflow = yaml.safe_load((root / ".github/workflows/ci.yml").read_text())
command = "./tool/android_repeat_native_test.sh"

def validate(check, workflow):
    lines = [shlex.split(line, comments=True) for line in check.splitlines()
             if command in line]
    assert lines == [["run_step", "Android repeat bridge JVM", command]], "check.sh must run the bridge without swallowing failure"
    native = workflow["jobs"]["native"]
    assert "if" not in native and native.get("continue-on-error", False) is False, "native job must run and propagate failure"
    steps = [step for step in native["steps"] if command in str(step.get("run", ""))]
    assert len(steps) == 1 and steps[0]["run"].strip() == command, "CI must run the bridge without swallowing failure"
    assert "if" not in steps[0] and steps[0].get("continue-on-error", False) is False, "bridge step must run and propagate failure"
    ci = workflow["jobs"]["ci"]
    assert "native" in ci["needs"], "CI aggregate must require native"
    assert ci.get("continue-on-error", False) is False
    assert any('test "${{ needs.native.result }}" = success' in step.get("run", "")
               and "||" not in step["run"] and "if" not in step
               and step.get("continue-on-error", False) is False for step in ci["steps"])

validate(check, workflow)
# Prove the contract rejects silent skips and swallowed failures.
for target in ("step", "job"):
    for key, value in (("continue-on-error", True), ("if", False)):
        broken = copy.deepcopy(workflow)
        native = broken["jobs"]["native"]
        subject = native if target == "job" else next(s for s in native["steps"] if s.get("run") == command)
        subject[key] = value
        try:
            validate(check, broken)
        except AssertionError:
            pass
        else:
            raise AssertionError(f"contract accepted {target} {key}")

# Raw source variants also prove comments and shell suffixes cannot hide a gate.
workflow_source = (root / ".github/workflows/ci.yml").read_text()
for variant_command in ("./tool/android_repeat_native_test.sh", "./tool/android_repeat_runner_test.sh"):
    for replacement in (f"- run: {variant_command} || true", f"# - run: {variant_command}"):
        broken = workflow_source.replace(f"- run: {variant_command}", replacement)
        try:
            validate(check, yaml.safe_load(broken))
        except AssertionError:
            pass
        else:
            raise AssertionError(f"contract accepted {replacement}")
for variant_command, label in (("./tool/android_repeat_native_test.sh", "Android repeat bridge JVM"),
                       ("./tool/android_repeat_runner_test.sh", "Android repeat runner contract")):
    line = f'run_step "{label}" {variant_command}'
    for replacement in (f"{line} || true", f"# {line}"):
        try:
            validate(check.replace(line, replacement), workflow)
        except AssertionError:
            pass
        else:
            raise AssertionError(f"contract accepted {replacement}")
PYTHON
echo 'Android repeat runner: wrapper, bounds, nonzero test counts, failure propagation and gate wiring passed.'
