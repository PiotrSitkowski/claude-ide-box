#!/usr/bin/env bash
# Measure installing and testing a Node project with node_modules on a bind
# mount (the project directory, as without DEPS_VOLUMES) and on a named
# volume (as with DEPS_VOLUMES). On Docker Desktop for macOS the difference
# is the file sharing layer; on native Linux both are the same filesystem.
#
# Usage: tests/perf/deps-bench.sh [RUNS]
#
# It runs a plain node:22 container with network access (npm needs it): this
# is a measurement for developers, not part of the sandbox. Environment:
#   BENCH_IMAGE   node image (default node:22-bookworm-slim)
#   BENCH_FILES   number of test files (default 300)
#   BENCH_DOCKER_ARGS  extra `docker run` arguments (e.g. --network host)
set -euo pipefail

runs="${1:-3}"
image="${BENCH_IMAGE:-node:22-bookworm-slim}"
files="${BENCH_FILES:-300}"
# shellcheck disable=SC2206 # extra arguments are split on purpose
extra=(${BENCH_DOCKER_ARGS:-})

work="$(mktemp -d "${TMPDIR:-/tmp}/cb-bench.XXXXXX")"
work="$(cd -P "$work" && pwd -P)"
vol="cb-bench-$$"
cleanup() {
  docker run --rm -v "$work:/p" "$image" rm -rf /p/node_modules >/dev/null 2>&1 || true
  rm -rf "$work"
  docker volume rm -f "$vol" "$vol-cache" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A project in the shape that exposed the problem: TypeScript sources and
# tests run by vitest (esbuild and rollup are native), many small modules.
mkdir -p "$work/src" "$work/test"
cat >"$work/package.json" <<'EOF'
{ "name": "bench", "version": "1.0.0", "private": true, "type": "module",
  "scripts": { "test": "vitest run --reporter=dot" },
  "devDependencies": { "vitest": "2.1.9", "typescript": "5.6.3", "zod": "3.23.8" } }
EOF
i=0
while [ "$i" -lt "$files" ]; do
  printf 'import { z } from "zod";\nexport const s%d = z.object({ id: z.number(), name: z.string() });\nexport const f%d = (n: number): number => n * %d;\n' \
    "$i" "$i" "$i" >"$work/src/m$i.ts"
  printf 'import { expect, test } from "vitest";\nimport { f%d, s%d } from "../src/m%d";\ntest("m%d", () => { expect(f%d(2)).toBe(%d); expect(s%d.parse({ id: 1, name: "a" }).id).toBe(1); });\n' \
    "$i" "$i" "$i" "$i" "$i" "$((2 * i))" "$i" >"$work/test/m$i.test.ts"
  i=$((i + 1))
done

uidgid="$(id -u):$(id -g)"
# run MODE CMD - run CMD in the project with node_modules on MODE.
run() {
  local mode="$1"
  shift
  local -a m
  # The npm cache is on its own volume, warm after the first install, so
  # `npm ci` measures unpacking into node_modules rather than downloads.
  m=(-v "$work:/p" --mount "type=volume,src=$vol-cache,dst=/cache")
  if [ "$mode" = volume ]; then
    m+=(--mount "type=volume,src=$vol,dst=/p/node_modules")
  fi
  docker run --rm ${extra[@]+"${extra[@]}"} --user "$uidgid" -e HOME=/tmp -e npm_config_cache=/cache \
    -e npm_config_update_notifier=false "${m[@]}" -w /p "$image" sh -c "$*"
}

# Sub-second clock: perl ships with macOS; BSD date has no %N.
now() {
  perl -MTime::HiRes=time -e 'printf "%.3f\n", time' 2>/dev/null || date +%s
}

seconds() {
  local start end
  start="$(now)"
  "$@" >/dev/null 2>&1
  end="$(now)"
  awk -v a="$start" -v b="$end" 'BEGIN { printf "%.1f", b - a }'
}

median() {
  tr ' ' '\n' | grep -v '^$' | sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }'
}

docker volume create "$vol-cache" >/dev/null
docker run --rm --user 0 -v "$vol-cache:/v" "$image" chown "$uidgid" /v
echo "== creating the lockfile"
run bind "npm install --no-audit --no-fund >/dev/null" || { echo "npm install failed" >&2; exit 1; }
run bind "rm -rf node_modules"
docker volume create "$vol" >/dev/null
docker run --rm --user 0 -v "$vol:/v" "$image" chown "$uidgid" /v

printf '%-8s %-10s %s\n' mode step "seconds (median of $runs)"
for mode in bind volume; do
  ci=""
  tests=""
  r=0
  while [ "$r" -lt "$runs" ]; do
    run "$mode" "rm -rf node_modules/* node_modules/.[!.]* 2>/dev/null; true"
    ci="$ci $(seconds run "$mode" "npm ci --no-audit --no-fund")"
    tests="$tests $(seconds run "$mode" "npx vitest run --reporter=dot")"
    r=$((r + 1))
  done
  printf '%-8s %-10s %s   (runs:%s)\n' "$mode" "npm ci" "$(printf '%s' "$ci" | median)" "$ci"
  printf '%-8s %-10s %s   (runs:%s)\n' "$mode" "vitest" "$(printf '%s' "$tests" | median)" "$tests"
done
echo "host: $(uname -sm), docker $(docker version --format '{{.Server.Version}}' 2>/dev/null), $files test files"
