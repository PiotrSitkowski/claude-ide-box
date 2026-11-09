# shellcheck shell=bash
# Unit tests for the default secret masks, conditional masks (.mcp.json) and
# the secret scan that runs when a project container is created.

container() {
  printf 'claude-ide-box-my-project-%s\n' "$(sha8 "$PROJECT")"
}

project_conf() {
  mkdir -p "$HOME/.config/claude-ide-box/projects"
  printf '%s\n' "$@" >"$HOME/.config/claude-ide-box/projects/$(container).conf"
}

wrapper_log() {
  cat "$HOME/.local/state/claude-ide-box/wrapper.log" 2>/dev/null || true
}

masked() {
  # masked PATH - the container gets an empty read-only file at PATH
  case "$(run_args)" in
    *"type=bind,src=$HOME/.local/state/claude-ide-box/empty,dst=$PROJECT/$1,readonly"*) return 0 ;;
  esac
  return 1
}

# Secret-looking values used below. None of them may ever be printed.
V_QUERY="qZ7xR2mK9pL4wN8v"
V_JSON="AbCdEf123456XyZw9876"
V_NPM="npm_Q1w2E3r4T5y6U7i8O9p0"
V_ENV="BSAk3j4h5g6f7d8s9a0zz"

assert_no_secret_values() {
  local v
  for v in "$V_QUERY" "$V_JSON" "$V_NPM" "$V_ENV"; do
    assert_not_contains "$OUT" "$v" "a secret value reached stdout"
    assert_not_contains "$ERR" "$v" "a secret value reached stderr"
    assert_not_contains "$(wrapper_log)" "$v" "a secret value reached the log"
  done
}

# --- default masks ----------------------------------------------------------

test_new_default_masks() {
  local f
  mkdir -p "$PROJECT/certs" "$PROJECT/tls" "$PROJECT/worker" "$PROJECT/gcp"
  for f in .dev.vars worker/.dev.vars.production .npmrc .netrc .envrc certs/server.pem \
    tls/server.key credentials.json gcp/credentials-staging.json gcp/service-account-prod.json; do
    echo x >"$PROJECT/$f"
  done
  run_wrapper --version
  assert_status 0 "$STATUS"
  for f in .dev.vars worker/.dev.vars.production .npmrc .netrc .envrc certs/server.pem \
    tls/server.key credentials.json gcp/credentials-staging.json gcp/service-account-prod.json; do
    masked "$f" || fail "$f is not masked"
  done
}

test_ordinary_config_files_are_not_masked() {
  echo '{"name":"x"}' >"$PROJECT/package.json"
  echo '{}' >"$PROJECT/tsconfig.json"
  run_wrapper --version
  masked package.json && fail "package.json must not be masked"
  masked tsconfig.json && fail "tsconfig.json must not be masked"
  return 0
}

test_default_masks_can_be_narrowed_per_project() {
  echo x >"$PROJECT/.npmrc"
  echo x >"$PROJECT/.env"
  project_conf 'MASK_DEFAULTS=".env .env.*"'
  run_wrapper --version
  masked .env || fail ".env is not masked"
  masked .npmrc && fail ".npmrc must not be masked when MASK_DEFAULTS leaves it out"
  return 0
}

# --- .mcp.json: masked only when it holds a secret ------------------------------

test_mcp_json_without_secret_is_visible() {
  cat >"$PROJECT/.mcp.json" <<'EOF'
{ "mcpServers": { "playwright": { "command": "npx", "args": ["-y", "@playwright/mcp@0.0.41"] },
  "docs": { "type": "http", "url": "https://mcp.example.com/mcp" } } }
EOF
  run_wrapper --version
  masked .mcp.json && fail ".mcp.json without a secret must stay visible"
  return 0
}

test_mcp_json_with_key_in_url_query_is_masked() {
  cat >"$PROJECT/.mcp.json" <<EOF
{ "mcpServers": { "search": { "type": "sse", "url": "https://mcp.example.com/sse?api_key=$V_QUERY" } } }
EOF
  run_wrapper --version
  assert_status 0 "$STATUS"
  masked .mcp.json || fail ".mcp.json with a key in the URL is not masked"
  assert_no_secret_values
}

test_mcp_json_with_literal_env_value_is_masked() {
  cat >"$PROJECT/.mcp.json" <<EOF
{ "mcpServers": { "brave": { "command": "npx", "args": ["-y", "brave-search-mcp"],
  "env": { "BRAVE_KEY": "$V_ENV" } } } }
EOF
  run_wrapper --version
  masked .mcp.json || fail ".mcp.json with a literal env value is not masked"
  assert_no_secret_values
}

test_mcp_json_with_authorization_header_is_masked() {
  cat >"$PROJECT/.mcp.json" <<EOF
{ "mcpServers": { "api": { "type": "http", "url": "https://mcp.example.com/mcp",
  "headers": { "Authorization": "Bearer $V_JSON" } } } }
EOF
  run_wrapper --version
  masked .mcp.json || fail ".mcp.json with an Authorization header is not masked"
}

test_mcp_json_with_env_placeholders_is_visible() {
  cat >"$PROJECT/.mcp.json" <<'EOF'
{ "mcpServers": { "api": { "type": "http", "url": "https://mcp.example.com/mcp?api_key=${MCP_API_KEY}",
  "headers": { "Authorization": "Bearer ${MCP_TOKEN}" }, "env": { "KEY": "${MCP_KEY}" } } } }
EOF
  run_wrapper --version
  masked .mcp.json && fail ".mcp.json with only \${VAR} placeholders must stay visible"
  return 0
}

test_mcp_json_gaining_a_secret_recreates_the_container() {
  echo '{ "mcpServers": {} }' >"$PROJECT/.mcp.json"
  run_wrapper --version
  masked .mcp.json && fail "not masked yet"
  printf '{ "mcpServers": { "a": { "url": "https://x.example.com/?token=%s" } } }\n' "$V_QUERY" >"$PROJECT/.mcp.json"
  run_wrapper --version
  assert_status 0 "$STATUS"
  masked .mcp.json || fail ".mcp.json must be masked after a secret appeared in it"
}

# --- secret scan on container creation ------------------------------------------

test_scan_finds_secret_in_url_query_string() {
  mkdir -p "$PROJECT/deploy"
  printf 'name: hooks\nwebhook: https://hooks.example.com/notify?token=%s&x=1\n' "$V_QUERY" >"$PROJECT/deploy/hooks.yaml"
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_eq "FAKE-STDOUT" "$OUT"
  assert_contains "$ERR" "deploy/hooks.yaml"
  assert_contains "$ERR" "line 2"
  assert_contains "$ERR" "claude-ide-box mask deploy/hooks.yaml"
  assert_contains "$(wrapper_log)" "deploy/hooks.yaml"
  assert_no_secret_values
}

test_scan_finds_secret_in_json() {
  mkdir -p "$PROJECT/config"
  printf '{\n  "service": "mail",\n  "apiKey": "%s"\n}\n' "$V_JSON" >"$PROJECT/config/app.json"
  run_wrapper --version
  assert_contains "$ERR" "config/app.json"
  assert_contains "$ERR" "line 3"
  assert_contains "$ERR" "claude-ide-box mask config/app.json"
  assert_no_secret_values
}

test_scan_finds_token_in_npmrc_when_npmrc_is_not_masked() {
  project_conf 'MASK_DEFAULTS=".env .env.*"'
  printf 'engine-strict=true\n//registry.npmjs.org/:_authToken=%s\n' "$V_NPM" >"$PROJECT/.npmrc"
  run_wrapper --version
  assert_contains "$ERR" ".npmrc"
  assert_contains "$ERR" "line 2"
  assert_no_secret_values
}

test_scan_finds_known_token_formats_and_private_keys() {
  mkdir -p "$PROJECT/ops"
  printf 'x = "ghp_%s"\n' "abcdefghijklmnopqrstuvwxyz0123456789" >"$PROJECT/ops/ci.toml"
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n' >"$PROJECT/ops/deploy_id"
  run_wrapper --version
  assert_contains "$ERR" "ops/ci.toml"
  assert_contains "$ERR" "ops/deploy_id"
  assert_not_contains "$ERR" "abcdefghijklmnopqrstuvwxyz0123456789"
}

test_scan_ignores_placeholders_and_ordinary_config() {
  mkdir -p "$PROJECT/config"
  cat >"$PROJECT/package.json" <<'EOF'
{ "name": "app", "version": "1.2.3", "author": "Jane Example <jane@example.com>",
  "devDependencies": { "@secretlint/secretlint-rule-preset-recommend": "^9.0.0", "jsonwebtoken": "^9.0.2" } }
EOF
  cat >"$PROJECT/config/app.json" <<'EOF'
{ "apiKey": "${API_KEY}", "token": "", "url": "https://api.example.com/v1?page=2", "password": "<set me>" }
EOF
  run_wrapper --version
  assert_not_contains "$ERR" "possible secret"
}

test_scan_skips_masked_files_dependencies_and_lockfiles() {
  mkdir -p "$PROJECT/node_modules/pkg"
  printf 'TOKEN=%s\n' "$V_JSON" >"$PROJECT/.env"
  printf '{ "apiKey": "%s" }\n' "$V_JSON" >"$PROJECT/node_modules/pkg/config.json"
  printf '{ "apiKey": "%s" }\n' "$V_JSON" >"$PROJECT/package-lock.json"
  run_wrapper --version
  assert_not_contains "$ERR" "possible secret"
}

test_scan_runs_only_when_the_container_is_created() {
  run_wrapper --version
  mkdir -p "$PROJECT/config"
  printf '{ "apiKey": "%s" }\n' "$V_JSON" >"$PROJECT/config/app.json"
  run_wrapper --version
  assert_not_contains "$ERR" "possible secret"
}

test_scan_can_be_turned_off_per_project() {
  project_conf 'SECRET_SCAN=0'
  mkdir -p "$PROJECT/config"
  printf '{ "apiKey": "%s" }\n' "$V_JSON" >"$PROJECT/config/app.json"
  run_wrapper --version
  assert_status 0 "$STATUS"
  assert_not_contains "$ERR" "possible secret"
}

# --- scan and mask commands ------------------------------------------------------

test_scan_command_lists_findings_without_values() {
  mkdir -p "$PROJECT/config"
  printf '{ "apiKey": "%s" }\n' "$V_JSON" >"$PROJECT/config/app.json"
  run_cli scan
  assert_status 0 "$STATUS"
  assert_contains "$OUT$ERR" "config/app.json"
  assert_contains "$OUT$ERR" "claude-ide-box mask config/app.json"
  assert_no_secret_values
}

test_scan_command_reports_a_clean_project() {
  echo '{}' >"$PROJECT/package.json"
  run_cli scan
  assert_status 0 "$STATUS"
  assert_contains "$OUT" "no secret-looking values found"
}

test_mask_command_adds_a_per_project_mask() {
  mkdir -p "$PROJECT/config"
  printf '{ "apiKey": "%s" }\n' "$V_JSON" >"$PROJECT/config/app.json"
  run_cli mask config/app.json
  assert_status 0 "$STATUS"
  assert_contains "$(cat "$HOME/.config/claude-ide-box/projects/$(container).conf")" 'MASK="config/app.json"'
  run_cli mask
  assert_contains "$OUT" "config/app.json"
  run_cli scan
  assert_not_contains "$OUT$ERR" "possible secret"
  run_cli up
  masked config/app.json || fail "config/app.json is not masked after 'mask'"
}

test_mask_command_rejects_paths_outside_the_project() {
  run_cli mask ../x
  assert_nonzero "$STATUS"
  run_cli mask /etc/passwd
  assert_nonzero "$STATUS"
  run_cli mask 'a b'
  assert_nonzero "$STATUS"
}

test_mask_remove() {
  run_cli mask config/a.json secrets.yml
  run_cli mask --remove secrets.yml
  assert_status 0 "$STATUS"
  assert_contains "$(cat "$HOME/.config/claude-ide-box/projects/$(container).conf")" 'MASK="config/a.json"'
}

test_doctor_reports_possible_secrets_in_the_project() {
  mkdir -p "$PROJECT/config"
  printf '{ "apiKey": "%s" }\n' "$V_JSON" >"$PROJECT/config/app.json"
  run_cli doctor
  assert_contains "$OUT" "[warn]"
  assert_contains "$OUT" "config/app.json"
  assert_no_secret_values
}
