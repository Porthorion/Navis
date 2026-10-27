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
import pathlib
import re
import shlex
import sys

root = pathlib.Path(sys.argv[1])
check = (root / "tool/check.sh").read_text()
workflow = (root / ".github/workflows/ci.yml").read_text()
commands = (("./tool/android_repeat_native_test.sh", "Android repeat bridge JVM"),
            ("./tool/android_repeat_runner_test.sh", "Android repeat runner contract"))

def job(source, name):
    blocks = re.findall(rf"(?ms)^  {name}:\s*\n(.*?)(?=^  \S|\Z)", source)
    assert len(blocks) == 1, f"expected one {name} job in the maintained workflow layout"
    return blocks[0]

def validate(check, workflow):
    # Accept the repository's block/inline-step layout; unsupported forms fail closed.
    native = job(workflow, "native")
    ci = job(workflow, "ci")
    # Quoted keys and anchors/aliases/merges would evade these line checks: fail closed on them.
    assert not re.search(r"(?:^|[\s:\[,-])[&*][\w-]|<<\s*:", native + ci), "native/ci jobs must not use YAML anchors, aliases or merges"
    assert not re.search(r"^\s*(?:-\s+)?[\"']?(?:if|continue-on-error)[\"']?\s*:", native, re.M), "native job and steps must run and propagate failure"
    runs = re.findall(r"^      - run: (.+)$", native, re.M)
    for command, label in commands:
        lines = [shlex.split(line, comments=True) for line in check.splitlines() if command in line]
        assert lines == [["run_step", label, command]], f"check.sh must run {command} without swallowing failure"
        assert [line for line in runs if command in line] == [command], f"CI must run {command} without swallowing failure"
    needs = re.findall(r"^    needs: \[([^\]]+)\]$", ci, re.M)
    assert len(needs) == 1 and "native" in [name.strip() for name in needs[0].split(",")], "CI aggregate must require native"
    assert not re.search(r"^\s*(?:-\s+)?[\"']?continue-on-error[\"']?\s*:", ci, re.M)
    assert re.findall(r"^\s*(?:-\s+)?[\"']?if[\"']?\s*:.*$", ci, re.M) == ["    if: always()"]
    gate = ' && '.join(f'test "${{{{ needs.{name}.result }}}}" = success' for name in ("static", "test", "tooling", "native"))
    assert re.findall(r"^      - run: (.+)$", ci, re.M) == [gate], "CI aggregate must enforce each job's success"

validate(check, workflow)
negative_count = 0

def rejects(broken_check, broken_workflow, label):
    global negative_count
    try:
        validate(broken_check, broken_workflow)
    except AssertionError:
        negative_count += 1
    else:
        raise AssertionError(f"contract accepted {label}")

# Keep the previously scratch-only failure, comment-out and removal variants here.
for command, label in commands:
    step = f"- run: {command}"
    line = f'run_step "{label}" {command}'
    assert workflow.count(step) == 1 and check.count(line) == 1
    for replacement in (f"{step} || true", f"# {step}", ""):
        rejects(check, workflow.replace(step, replacement), replacement or f"removed {step}")
    for replacement in (f"{line} || true", f"# {line}", ""):
        rejects(check.replace(line, replacement), workflow, replacement or f"removed {line}")
    for key in ("continue-on-error: true", "if: false", '"if": false', "'continue-on-error': true"):
        rejects(check, workflow.replace(step, f"{step}\n        {key}"), f"{command} {key}")
    rejects(check, workflow.replace(step, f"{step}\n        <<: *skip"), f"{command} merged alias")
for key in ("continue-on-error: true", "if: false", '"if": false', '"continue-on-error": true'):
    rejects(check, workflow.replace("  native:\n", f"  native:\n    {key}\n"), f"native {key}")
rejects(check, workflow.replace("  ci:\n", '  ci:\n    "continue-on-error": true\n'), 'ci quoted continue-on-error')
print(f"Android repeat CI contract: {negative_count} negative variants rejected (stdlib).")
PYTHON
echo 'Android repeat runner: wrapper, bounds, nonzero test counts, failure propagation and gate wiring passed.'
