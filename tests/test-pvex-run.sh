#!/usr/bin/env bash
# Checks the command line bin/pvex-run builds for each runner, using its
# dry-run mode. Run from anywhere: bash tests/test-pvex-run.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run_bin="$here/../bin/pvex-run"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fails=0
pass() { echo "  ok   $1"; }
fail() {
  echo "  FAIL $1"
  echo "$2" | sed 's/^/         /'
  fails=$((fails + 1))
}

# write_conf RUNNER PACKAGE COMMAND ARGS
write_conf() {
  {
    printf 'PVEX_RUNNER=%q\n' "$1"
    printf 'PVEX_PACKAGE=%q\n' "$2"
    printf 'PVEX_COMMAND=%q\n' "$3"
    printf 'PVEX_ARGS=%q\n' "$4"
  } >"$tmp/pvex.conf"
}

# expect NAME EXPECTED_LINES [pvex-run args...]
expect() {
  local name="$1" want="$2" got
  shift 2
  got="$(PVEX_CONF="$tmp/pvex.conf" PVEX_HOME="$tmp" PVEX_DRY_RUN=1 "$run_bin" "$@" 2>&1)" || {
    fail "$name" "exit $? — $got"
    return
  }
  if [[ "$got" == "$want" ]]; then pass "$name"; else fail "$name" "want:"$'\n'"$want"$'\n'"got:"$'\n'"$got"; fi
}

# join arguments with newlines, the way dry-run prints argv
lines() {
  local IFS=$'\n'
  printf '%s' "$*"
}

echo "pvex-run"

write_conf npx my-app "" "--host 0.0.0.0 --port 8080"
expect "npx: package and args" "$(lines npx -y my-app --host 0.0.0.0 --port 8080)"
expect "npx: extra args after --" "$(lines npx -y my-app --host 0.0.0.0 --port 8080 --debug)" -- --debug
expect "npx: --check resolves without running" "$(lines npx -y --package my-app -c 'exit 0')" --check

write_conf npx @scope/my-app@1.2.3 serve ""
expect "npx: command differs from package" "$(lines npx -y --package @scope/my-app@1.2.3 -- serve)"

write_conf bunx my-app "" "-p 3000"
expect "bunx: package and args" "$(lines bunx my-app -p 3000)"
write_conf bunx my-app@2 serve ""
expect "bunx: command differs from package" "$(lines bunx --package my-app@2 serve)"
expect "bunx: --check installs the package and runs true" "$(lines bunx --package my-app@2 true)" --check

write_conf uvx mcp-proxy "" "--port 8096"
expect "uvx: package and args" "$(lines uvx mcp-proxy --port 8096)"
expect "uvx: --check installs the tool env" "$(lines uvx --from mcp-proxy python -c pass)" --check
write_conf uvx 'my-tool[extra]==1.4.0' my-tool-serve ""
expect "uvx: command differs from package" "$(lines uvx --from 'my-tool[extra]==1.4.0' my-tool-serve)"

write_conf npx my-app "" "--name 'My App' --flag"
expect "quoted PVEX_ARGS stay one argument" "$(lines npx -y my-app --name 'My App' --flag)"
expect "--only replaces PVEX_ARGS" "$(lines npx -y my-app --init --data-dir /var/lib/pvex/data)" --only --init --data-dir /var/lib/pvex/data
expect "--only accepts a following --" "$(lines npx -y my-app --init)" --only -- --init
expect "--only with --check-like arg passes it through" "$(lines npx -y my-app --check)" --only --check

# app.env is loaded before PVEX_ARGS is parsed, so a value may refer to it.
printf "TITLE=My\\ App\nHOST=0.0.0.0\n" >"$tmp/app.env"
write_conf npx my-app "" '--title "$TITLE" --host "$HOST"'
got="$(PVEX_CONF="$tmp/pvex.conf" PVEX_ENV_FILE="$tmp/app.env" PVEX_HOME="$tmp" PVEX_DRY_RUN=1 "$run_bin" 2>&1)"
if [[ "$got" == "$(lines npx -y my-app --title 'My App' --host 0.0.0.0)" ]]; then pass "app.env is loaded"; else fail "app.env is loaded" "$got"; fi
write_conf npx my-app "" "--port 80"
got="$(PVEX_CONF="$tmp/pvex.conf" PVEX_ENV_FILE="$tmp/missing.env" PVEX_HOME="$tmp" PVEX_DRY_RUN=1 "$run_bin" 2>&1)"
if [[ "$got" == "$(lines npx -y my-app --port 80)" ]]; then pass "missing app.env is not an error"; else fail "missing app.env is not an error" "$got"; fi

if out="$(PVEX_CONF="$tmp/missing.conf" PVEX_HOME="$tmp" "$run_bin" 2>&1)"; then
  fail "missing conf fails" "$out"
else
  [[ $? -eq 78 ]] && pass "missing conf exits 78" || fail "missing conf exits 78" "$out"
fi

write_conf pipx my-app "" ""
if out="$(PVEX_CONF="$tmp/pvex.conf" PVEX_HOME="$tmp" PVEX_DRY_RUN=1 "$run_bin" 2>&1)"; then
  fail "unknown runner fails" "$out"
else
  [[ $? -eq 78 ]] && pass "unknown runner exits 78" || fail "unknown runner exits 78" "$out"
fi

echo
if ((fails)); then
  echo "$fails failure(s)"
  exit 1
fi
echo "all passed"
