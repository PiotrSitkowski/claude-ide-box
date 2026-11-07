# shellcheck shell=bash
# Unit tests for the minimum Docker versions: Docker Desktop, Docker Engine
# and runc versions with known container escapes are refused by setup, doctor
# and the wrapper; the thresholds live in one data file.

# engine ENGINE PLATFORM RUNC - what `docker version` reports.
engine() {
  local comps="Engine=$1;containerd=1.7.27;"
  [ -z "$3" ] || comps="${comps}runc=$3;"
  FAKE_ENGINE_INFO="$1|$2|${comps}docker-init=0.19.0;"
  export FAKE_ENGINE_INFO
}

global_conf() {
  mkdir -p "$HOME/.config/claude-ide-box"
  printf '%s\n' "$@" >"$HOME/.config/claude-ide-box/config"
}

doctor_line() {
  # the doctor line about the container engine
  printf '%s\n' "$OUT" | grep -E 'Docker Desktop|Docker Engine|runc|Podman|engine version|ALLOW_VULNERABLE_DOCKER' || true
}

# --- data -------------------------------------------------------------------

test_thresholds_are_data_with_cve_and_source() {
  local f="$REPO_DIR/lib/claude-ide-box/engine-versions.txt"
  assert_file_exists "$f"
  assert_contains "$(cat "$f")" "CVE-2025-9074"
  assert_contains "$(cat "$f")" "CVE-2024-21626"
  assert_contains "$(cat "$f")" "https://"
  # no version threshold is hard-coded in the scripts
  assert_not_contains "$(cat "$REPO_DIR/lib/claude-ide-box/engine.sh" "$REPO_DIR/bin/claude-ide-box")" "4.44.3"
  assert_not_contains "$(cat "$REPO_DIR/lib/claude-ide-box/engine.sh" "$REPO_DIR/bin/claude-ide-box")" "1.1.12"
}

# --- boundaries -------------------------------------------------------------

test_docker_desktop_boundaries() {
  engine 28.3.3 "Docker Desktop 4.44.2 (202017)" 1.2.5
  run_cli doctor
  assert_nonzero "$STATUS"
  assert_contains "$(doctor_line)" "[FAIL]"
  assert_contains "$(doctor_line)" "CVE-2025-9074"
  assert_contains "$(doctor_line)" "https://"

  engine 28.3.3 "Docker Desktop 4.44.3 (202357)" 1.2.5
  run_cli doctor
  assert_not_contains "$(doctor_line)" "[FAIL]"
  assert_contains "$(doctor_line)" "[warn]"

  engine 29.9.2 "Docker Desktop 4.97.0 (300100)" 1.3.4
  run_cli doctor
  assert_not_contains "$(doctor_line)" "[FAIL]"
  assert_not_contains "$(doctor_line)" "[warn]"

  engine 29.9.2 "Docker Desktop 4.98.0 (301000)" 1.3.4
  run_cli doctor
  assert_contains "$(doctor_line)" "[ ok ]"
  assert_contains "$(doctor_line)" "4.98.0"
}

test_docker_engine_boundaries() {
  local v
  for v in 25.0.1 24.0.8 23.0.6 20.10.27; do
    engine "$v" "Docker Engine - Community" 1.2.5
    run_cli doctor
    assert_contains "$(doctor_line)" "[FAIL]" "Docker Engine $v must fail"
    assert_contains "$(doctor_line)" "CVE-2024-21626"
  done
  for v in 25.0.2 24.0.9 26.1.0 29.9.2; do
    engine "$v" "Docker Engine - Community" 1.2.5
    run_cli doctor
    assert_not_contains "$(doctor_line)" "[FAIL]" "Docker Engine $v must pass"
  done
}

test_runc_boundaries() {
  engine 29.9.2 "Docker Engine - Community" 1.1.11
  run_cli doctor
  assert_contains "$(doctor_line)" "[FAIL]"
  assert_contains "$(doctor_line)" "runc 1.1.11"
  engine 29.9.2 "Docker Engine - Community" 1.1.12
  run_cli doctor
  assert_not_contains "$(doctor_line)" "[FAIL]"
  engine 29.9.2 "Docker Engine - Community" 1.0.0-rc95
  run_cli doctor
  assert_contains "$(doctor_line)" "[FAIL]"
}

test_versions_with_suffixes() {
  engine 29.9.2-rd "" 1.1.12-0ubuntu2~22.04.1
  run_cli doctor
  assert_not_contains "$(doctor_line)" "[FAIL]"
  engine 25.0.1-rd "" v1.1.14
  run_cli doctor
  assert_contains "$(doctor_line)" "[FAIL]"
  engine 28.0.4+azure-1 "" "1.2.6 (commit abc)"
  run_cli doctor
  assert_not_contains "$(doctor_line)" "[FAIL]"
  engine 28.3.3 "Docker Desktop 4.44.3 (12345)" 1.2.5
  run_cli doctor
  assert_not_contains "$(doctor_line)" "[FAIL]"
  engine 28.3.3 "Docker Desktop 4.10.0 (82025)" 1.2.5
  run_cli doctor
  assert_contains "$(doctor_line)" "[FAIL]"
}

test_versions_compare_numerically_not_as_text() {
  # 4.100.0 > 4.97.0 and 4.9.0 < 4.44.3, which a text comparison gets wrong
  engine 29.9.2 "Docker Desktop 4.100.0 (1)" 1.3.4
  run_cli doctor
  assert_not_contains "$(doctor_line)" "[FAIL]"
  assert_not_contains "$(doctor_line)" "[warn]"
  engine 29.9.2 "Docker Desktop 4.9.0 (1)" 1.3.4
  run_cli doctor
  assert_contains "$(doctor_line)" "[FAIL]"
}

# --- unreadable versions fail, never pass -----------------------------------------

test_unreadable_engine_version_fails() {
  local v
  for v in "" unknown "dev" "<no value>"; do
    engine "$v" "Docker Engine - Community" 1.2.5
    run_cli doctor
    assert_nonzero "$STATUS" "engine version '$v'"
    assert_contains "$(doctor_line)" "[FAIL]" "engine version '$v'"
  done
}

test_missing_runc_version_fails() {
  engine 29.9.2 "Docker Engine - Community" ""
  run_cli doctor
  assert_contains "$(doctor_line)" "[FAIL]"
  assert_contains "$(doctor_line)" "runc"
}

test_unreadable_desktop_version_fails() {
  engine 28.3.3 "Docker Desktop" 1.2.5
  run_cli doctor
  assert_contains "$(doctor_line)" "[FAIL]"
  assert_contains "$(doctor_line)" "Docker Desktop"
}

# --- enforcement --------------------------------------------------------------

test_setup_refuses_a_vulnerable_docker() {
  engine 28.3.3 "Docker Desktop 4.44.2 (1)" 1.2.5
  run_cli setup
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "CVE-2025-9074"
  assert_contains "$ERR" "ALLOW_VULNERABLE_DOCKER"
  assert_not_contains "$(cat "$FAKE_DOCKER_DIR/calls")" "build"
}

test_setup_warns_below_the_latest_isolation_fix() {
  engine 28.3.3 "Docker Desktop 4.50.0 (1)" 1.2.5
  run_cli setup
  assert_status 0 "$STATUS"
  assert_contains "$ERR" "warning"
  assert_contains "$ERR" "4.97.0"
}

test_wrapper_refuses_a_vulnerable_docker() {
  engine 24.0.7 "Docker Engine - Community" 1.1.10
  run_wrapper --version
  assert_nonzero "$STATUS"
  assert_eq "" "$OUT" "nothing on stdout"
  assert_contains "$ERR" "CVE-2024-21626"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args"
  assert_file_missing "$FAKE_DOCKER_DIR/exec.args"
}

test_up_refuses_a_vulnerable_docker() {
  engine 24.0.7 "Docker Engine - Community" 1.1.12
  run_cli up
  assert_nonzero "$STATUS"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args"
}

test_wrapper_runs_on_a_current_docker() {
  engine 29.9.2 "Docker Desktop 4.98.0 (1)" 1.3.4
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_eq "FAKE-STDOUT" "$OUT"
}

test_escape_hatch_lets_setup_and_wrapper_run_and_doctor_says_so() {
  global_conf ALLOW_VULNERABLE_DOCKER=1
  engine 28.3.3 "Docker Desktop 4.44.2 (1)" 1.2.5
  run_cli setup
  assert_status 0 "$STATUS"
  assert_contains "$ERR" "CVE-2025-9074"
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_eq "FAKE-STDOUT" "$OUT"
  run_cli doctor
  assert_nonzero "$STATUS" "doctor still fails on a vulnerable Docker"
  assert_contains "$OUT" "[RISK]"
  assert_contains "$OUT" "ALLOW_VULNERABLE_DOCKER=1"
}

test_escape_hatch_is_shown_by_every_doctor() {
  global_conf ALLOW_VULNERABLE_DOCKER=1
  engine 29.9.2 "Docker Desktop 4.98.0 (1)" 1.3.4
  run_cli doctor
  assert_contains "$OUT" "[RISK]"
  assert_contains "$OUT" "ALLOW_VULNERABLE_DOCKER=1"
}

test_escape_hatch_must_be_0_or_1_and_global() {
  global_conf ALLOW_VULNERABLE_DOCKER=yes
  run_cli doctor
  assert_nonzero "$STATUS"
  rm -f "$HOME/.config/claude-ide-box/config"
  # a per-project file (which a person might be talked into editing for one
  # project) cannot open it
  mkdir -p "$HOME/.config/claude-ide-box/projects"
  printf 'ALLOW_VULNERABLE_DOCKER=1\n' >"$HOME/.config/claude-ide-box/projects/claude-ide-box-my-project-$(sha8 "$PROJECT").conf"
  engine 24.0.7 "Docker Engine - Community" 1.1.10
  run_wrapper --version
  assert_nonzero "$STATUS" "a project file cannot open the hatch"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args"
}

test_red_on_a_terminal_only() {
  engine 28.3.3 "Docker Desktop 4.44.2 (1)" 1.2.5
  run_cli doctor
  assert_not_contains "$OUT" $'\033[' "no colour codes when stdout is not a terminal"
}

# --- Podman -----------------------------------------------------------------

test_podman_is_reported_as_not_checked() {
  FAKE_ENGINE_INFO="5.4.2|Podman Engine|Podman Engine=5.4.2;Conmon=2.1.12;OCI Runtime (crun)=1.20;"
  export FAKE_ENGINE_INFO
  run_cli doctor
  assert_contains "$(doctor_line)" "[warn]"
  assert_contains "$(doctor_line)" "not checked"
  assert_not_contains "$(doctor_line)" "[FAIL]"
  run_wrapper --version
  assert_status 0 "$STATUS"
}

test_docker_desktop_without_a_version_in_its_name_fails() {
  # Docker Desktop's VM kernel is a linuxkit one; if the platform name does not
  # carry the Desktop version, the Desktop advisories cannot be skipped.
  FAKE_ENGINE_INFO="28.3.3||Engine=28.3.3;containerd=1.7.27;runc=1.2.5;docker-init=0.19.0;|6.10.14-linuxkit"
  export FAKE_ENGINE_INFO
  run_cli doctor
  assert_contains "$(doctor_line)" "[FAIL]"
  assert_contains "$(doctor_line)" "Docker Desktop"
  FAKE_ENGINE_INFO="28.3.3|Docker Engine - Community|Engine=28.3.3;containerd=1.7.27;runc=1.2.5;docker-init=0.19.0;|6.8.0-60-generic"
  run_cli doctor
  assert_not_contains "$(doctor_line)" "[FAIL]"
}
