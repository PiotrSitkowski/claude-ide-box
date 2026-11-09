# shellcheck shell=bash
# Unit tests for Podman and rootless engines (fake docker in Podman mode).

calls() { cat "$FAKE_DOCKER_DIR/calls" 2>/dev/null || true; }

test_engine_docker_run_args_unchanged() {
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_not_contains "$(run_args)" "--userns"
  assert_not_contains "$(run_args)" "--read-only-tmpfs"
}

test_podman_setup_disables_network_dns_instead_of_inhibit_ipv4() {
  FAKE_ENGINE=podman FAKE_NO_NETWORK=1 run_cli setup
  assert_status 0 "$STATUS" "$ERR"
  local create
  create="$(calls | grep 'network create' | grep -- --internal || true)"
  assert_contains "$create" "--internal"
  assert_contains "$create" "--disable-dns"
  assert_not_contains "$create" "inhibit_ipv4"
  assert_contains "$(calls)" "--read-only-tmpfs=false"
}

test_podman_rootful_run_args() {
  FAKE_ENGINE=podman run_wrapper --version
  assert_status 0 "$STATUS" "$ERR"
  local a
  a="$(run_args | tr '\n' ' ')"
  assert_contains "$a" "--read-only-tmpfs=false"
  assert_contains "$a" "--http-proxy=false"
  assert_contains "$a" "--tmpfs /dev/shm:rw,nosuid,nodev,noexec,"
  assert_contains "$a" "--read-only "
  assert_contains "$a" "--cap-drop ALL"
  assert_contains "$a" "--dns 127.0.0.1"
  assert_not_contains "$a" "--userns"
  assert_eq "FAKE-STDOUT" "$OUT"
}

test_podman_rootless_maps_the_host_user() {
  FAKE_ENGINE=podman FAKE_ROOTLESS=1 run_wrapper --version
  assert_status 0 "$STATUS" "$ERR"
  assert_contains "$(run_args | tr '\n' ' ')" "--userns=keep-id"
}

test_podman_rootless_without_cgroup_v2_is_refused() {
  FAKE_ENGINE=podman FAKE_ROOTLESS=1 FAKE_CGROUPS=v1 FAKE_CONTROLLERS='[]' run_wrapper --version
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "cgroup"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args"
  assert_eq "" "$OUT"
}

test_podman_missing_controller_is_refused() {
  FAKE_ENGINE=podman FAKE_CONTROLLERS='["cpu","memory"]' run_wrapper --version
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "pids"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args"
}

test_podman_cni_backend_is_refused() {
  FAKE_ENGINE=podman FAKE_NETWORK_BACKEND=cni run_wrapper --version
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "netavark"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args"
}

test_rootless_docker_is_refused() {
  FAKE_ROOTLESS=1 run_wrapper --version
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "rootless Docker"
  assert_contains "$ERR" "Podman"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args"
  FAKE_ROOTLESS=1 run_cli setup
  assert_nonzero "$STATUS"
  assert_not_contains "$(calls)" "network create"
}

test_docker_without_enforced_limits_is_refused() {
  FAKE_LIMITS="true false true" run_wrapper --version
  assert_nonzero "$STATUS"
  assert_contains "$ERR" "limit"
  assert_file_missing "$FAKE_DOCKER_DIR/run.args"
}

test_podman_cpu_count_is_read_from_host_cpus() {
  FAKE_ENGINE=podman FAKE_NCPU=1 run_wrapper --version
  assert_contains "$(run_args | tr '\n' ' ')" "--cpus 1 "
}

test_podman_doctor_checks_dns_free_internal_network() {
  FAKE_ENGINE=podman run_cli doctor
  assert_contains "$OUT" "Podman"
  assert_contains "$OUT" "internal"
  assert_not_contains "$OUT" "lets containers reach the host"
  FAKE_ENGINE=podman FAKE_NETWORK_INFO="true true 172.30.99.0/24" run_cli doctor
  assert_nonzero "$STATUS"
  assert_contains "$OUT" "DNS"
}

test_podman_login_maps_the_host_user() {
  # login is interactive; check the arguments it would use through setup's
  # own path instead: the profile home check runs with the same engine flags.
  FAKE_ENGINE=podman FAKE_ROOTLESS=1 run_cli setup --profile python
  assert_status 0 "$STATUS" "$ERR"
  assert_contains "$(calls | grep -- '--rm' | sed -n 1p)" "--userns=keep-id"
}

test_docker_name_without_path_is_resolved() {
  CLAUDE_IDE_BOX_DOCKER=docker run_wrapper --version
  assert_status 0 "$STATUS" "$ERR"
  assert_eq "FAKE-STDOUT" "$OUT"
}

test_base_images_are_fully_qualified() {
  # Podman resolves short names only with a TTY or configured registries.
  local f line
  for f in "$REPO_DIR"/image/profiles/*/Dockerfile "$REPO_DIR/image/Dockerfile" "$REPO_DIR/proxy/Dockerfile"; do
    while IFS= read -r line; do
      case "$line" in
        *BASE_IMAGE=claude-ide-box/*) ;;
        *=docker.io/*) ;;
        *) fail "$f: image reference is not fully qualified: $line" ;;
      esac
    done <<EOS
$(grep -E '^ARG [A-Z_]*IMAGE=' "$f")
EOS
  done
  grep -q 'CFG_BASE_IMAGE="docker.io/' "$REPO_DIR/lib/claude-ide-box/common.sh" || fail "default BASE_IMAGE is not fully qualified"
  grep -q 'CFG_PROXY_BASE_IMAGE="docker.io/' "$REPO_DIR/lib/claude-ide-box/common.sh" || fail "default PROXY_BASE_IMAGE is not fully qualified"
}

test_podman_directory_masks_do_not_copy_the_secrets_up() {
  # Podman fills a tmpfs mount with what lies underneath (tmpcopyup) unless
  # told not to - for a mask that would copy the secrets into it.
  mkdir -p "$PROJECT/.env.d"
  : >"$PROJECT/.env.d/prod"
  FAKE_ENGINE=podman run_wrapper --version
  assert_status 0 "$STATUS" "$ERR"
  assert_contains "$(run_args)" "type=tmpfs,dst=$PROJECT/.env.d,tmpfs-size=1048576,notmpcopyup"
  rm -f "$FAKE_DOCKER_DIR/state" "$FAKE_DOCKER_DIR/run.args"
  run_wrapper --version
  assert_contains "$(run_args)" "type=tmpfs,dst=$PROJECT/.env.d,tmpfs-size=1048576"
  assert_not_contains "$(run_args)" "notmpcopyup"
}
