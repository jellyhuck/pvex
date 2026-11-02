#!/usr/bin/env bash
# Checks the host-side helpers of ct/pvex.sh: engine ref selection, hostname
# slugs, spec validation, spec-file precedence and the files/hook payloads.
# PVEX_TEST=1 makes ct/pvex.sh return right after its helper block, before it
# would download the engine. Run from anywhere: bash tests/test-host-helpers.sh
# shellcheck disable=SC1090,SC2034 # the file sourced is ct/pvex.sh; PVEX_* are read by its helpers
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ct="$here/../ct/pvex.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fails=0
pass() { echo "  ok   $1"; }
fail() {
  echo "  FAIL $1"
  [[ -n "${2:-}" ]] && echo "$2" | sed 's/^/         /'
  fails=$((fails + 1))
}
check() { # NAME EXPECTED ACTUAL
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want: $2"$'\n'"got:  $3"; fi
}
# dies NAME -- COMMAND...: the command must exit 1 via pvex_die
dies() {
  local name="$1"
  shift 2
  local out
  out="$("$@" 2>&1)"
  if [[ $? -eq 1 && "$out" == *"pvex:"* ]]; then pass "$name"; else fail "$name" "$out"; fi
}

echo "engine ref"
(
  unset PVEX_CORE_REF
  PVEX_TEST=1 source "$ct"
  check "default pin" "https://raw.githubusercontent.com/community-scripts/core/$PVEX_CORE_DEFAULT_REF" "$_CS_CORE_DEFAULT_URL"
  [[ "$PVEX_CORE_DEFAULT_REF" =~ ^[0-9a-f]{40}$ ]] && pass "default pin is a commit" || fail "default pin is a commit" "$PVEX_CORE_DEFAULT_REF"
  exit $fails
)
fails=$((fails + $?))
(
  PVEX_CORE_REF=my-branch PVEX_TEST=1 source "$ct"
  check "PVEX_CORE_REF overrides the pin" "https://raw.githubusercontent.com/community-scripts/core/my-branch" "$_CS_CORE_DEFAULT_URL"
  exit $fails
)
fails=$((fails + $?))
(
  export COMMUNITY_SCRIPTS_CORE_URL="https://raw.githubusercontent.com/community-scripts/core/0123456789012345678901234567890123456789"
  PVEX_TEST=1 source "$ct"
  check "an upstream commit pin from /usr/bin/update is dropped" "" "${COMMUNITY_SCRIPTS_CORE_URL:-}"
  export COMMUNITY_SCRIPTS_CORE_URL="https://raw.githubusercontent.com/someone/core/fix-branch"
  PVEX_TEST=1 source "$ct"
  check "a fork URL is kept" "https://raw.githubusercontent.com/someone/core/fix-branch" "${COMMUNITY_SCRIPTS_CORE_URL:-}"
  exit $fails
)
fails=$((fails + $?))

# Everything below runs with the helpers loaded once.
PVEX_TEST=1 source "$ct"

echo "slug"
check "plain npm package" "my-app" "$(pvex_slug my-app)"
check "scoped and pinned npm package" "my-app" "$(pvex_slug @scope/my-app@1.2.3)"
check "npm tag" "my-app" "$(pvex_slug my-app@latest)"
check "python specifier and extras" "my-tool" "$(pvex_slug 'my_tool[extra]>=2.0')"
check "python exact pin" "mcp-proxy" "$(pvex_slug mcp-proxy==0.8.0)"
check "git url" "repo" "$(pvex_slug git+https://github.com/o/repo.git@v1)"
check "upper case and odd characters" "weird-name" "$(pvex_slug 'Weird__Name!')"
check "long names are cut to 50" "50" "$(pvex_slug "$(printf 'a%.0s' {1..80})" | wc -c | tr -d ' ')"

echo "validate"
(PVEX_RUNNER=npx PVEX_PACKAGE=my-app PVEX_PORT=8080 pvex_validate) && pass "a good spec passes" || fail "a good spec passes"
(PVEX_RUNNER=uvx PVEX_PACKAGE='my-tool[extra]==1.0' PVEX_COMMAND=my-tool pvex_validate) && pass "python extras pass" || fail "python extras pass"
(PVEX_RUNNER=uvx PVEX_PACKAGE='litellm[proxy]>=1.0,<2' pvex_validate) && pass "PEP 508 range specifier passes" || fail "PEP 508 range specifier passes"
(PVEX_RUNNER=npx PVEX_PACKAGE=my-app PVEX_ENV='HOST=0.0.0.0;TITLE=My App' pvex_validate) && pass "env entries with ; and spaces pass" || fail "env entries with ; and spaces pass"
(PVEX_RUNNER=npx PVEX_PACKAGE=my-app PVEX_ENV=$'DSN=a;b;c\n# note\nX=1' pvex_validate) && pass "multi-line env keeps ; in values" || fail "multi-line env keeps ; in values"
dies "env entry without =" -- env PVEX_RUNNER=npx PVEX_PACKAGE=x PVEX_ENV='HOST=0.0.0.0;DEBUG' bash -c "PVEX_TEST=1 source '$ct'; pvex_validate"
dies "env entry with a bad key" -- env PVEX_RUNNER=npx PVEX_PACKAGE=x PVEX_ENV='1X=a' bash -c "PVEX_TEST=1 source '$ct'; pvex_validate"
dies "unknown runner" -- env PVEX_RUNNER=pipx PVEX_PACKAGE=x bash -c "PVEX_TEST=1 source '$ct'; pvex_validate"
dies "missing package" -- env PVEX_RUNNER=npx bash -c "PVEX_TEST=1 source '$ct'; pvex_validate"
dies "whitespace in package" -- env PVEX_RUNNER=npx PVEX_PACKAGE='x;rm -rf /' bash -c "PVEX_TEST=1 source '$ct'; pvex_validate"
dies "control character in package" -- env PVEX_RUNNER=npx PVEX_PACKAGE=$'x\ty' bash -c "PVEX_TEST=1 source '$ct'; pvex_validate"
dies "space in command" -- env PVEX_RUNNER=npx PVEX_PACKAGE=x PVEX_COMMAND='a b' bash -c "PVEX_TEST=1 source '$ct'; pvex_validate"
dies "port out of range" -- env PVEX_RUNNER=npx PVEX_PACKAGE=x PVEX_PORT=70000 bash -c "PVEX_TEST=1 source '$ct'; pvex_validate"
dies "shell in PVEX_PACKAGES" -- env PVEX_RUNNER=npx PVEX_PACKAGE=x PVEX_PACKAGES='ffmpeg; id' bash -c "PVEX_TEST=1 source '$ct'; pvex_validate"

echo "env entries"
check "single line splits on ;" $'A=1\nB=2' "$(PVEX_ENV='A=1;B=2' pvex_env_entries)"
check "multi-line splits on newlines only" $'A=1;x\nB=2' "$(PVEX_ENV=$'A=1;x\nB=2' pvex_env_entries)"
check "empty env gives nothing" "" "$(PVEX_ENV='' pvex_env_entries)"

echo "spec file"
cat >"$tmp/app.pvex" <<'SPEC'
PVEX_RUNNER=uvx
PVEX_PACKAGE=file-pkg
PVEX_PORT=1234
PVEX_CORE_REF=spec-branch
var_ram=2048
var_disk=8
SPEC
out="$(
  export PVEX_PACKAGE=env-pkg var_ram=512
  pvex_load_spec_file "$tmp/app.pvex"
  # shellcheck disable=SC2154 # set by the spec file
  echo "$PVEX_RUNNER $PVEX_PACKAGE $PVEX_PORT $var_ram $var_disk"
)"
check "environment wins over the spec file, file fills the rest" "uvx env-pkg 1234 512 8" "$out"
out="$(unset PVEX_CORE_REF; PVEX_FILE="$tmp/app.pvex" PVEX_TEST=1 bash -c "source '$ct'; echo \"\$_CS_CORE_DEFAULT_URL\"")"
check "PVEX_CORE_REF from the spec file selects the engine" "https://raw.githubusercontent.com/community-scripts/core/spec-branch" "$out"
out="$(unset PVEX_CORE_REF PVEX_FILE; PVEX_TEST=1 bash -c "source '$ct' '$tmp/app.pvex'; echo \"\$_CS_CORE_DEFAULT_URL \$PVEX_PACKAGE\"")"
check "a spec file as first argument is loaded before the engine" "https://raw.githubusercontent.com/community-scripts/core/spec-branch file-pkg" "$out"
dies "missing spec file" -- bash -c "PVEX_TEST=1 source '$ct'; pvex_load_spec_file /nonexistent.pvex"

echo "files payload"
mkdir -p "$tmp/src"
printf 'listen: 0.0.0.0\n' >"$tmp/src/config.yaml"
printf 'secret\n' >"$tmp/src/token"
chmod 0600 "$tmp/src/token"
PVEX_FILES="$tmp/src/config.yaml:/etc/myapp/config.yaml; $tmp/src/token:/var/lib/pvex/.token
"
b64="$(pvex_pack_files)" || fail "pack files"
mkdir -p "$tmp/root"
base64 -d <<<"$b64" | tar -xzf - -C "$tmp/root"
check "config lands at its destination" "listen: 0.0.0.0" "$(cat "$tmp/root/etc/myapp/config.yaml")"
check "second entry after ';' lands too" "secret" "$(cat "$tmp/root/var/lib/pvex/.token")"
check "0600 source stays 0600" "600" "$(stat -c %a "$tmp/root/var/lib/pvex/.token")"
check "other files are 0644" "644" "$(stat -c %a "$tmp/root/etc/myapp/config.yaml")"
check "directories travel as 0755, not mktemp's 0700" "755" "$(stat -c %a "$tmp/root/etc")"
dies "relative destination" -- env PVEX_FILES="$tmp/src/config.yaml:etc/x" bash -c "PVEX_TEST=1 source '$ct'; pvex_pack_files"
dies "missing source" -- env PVEX_FILES="$tmp/src/nope:/etc/x" bash -c "PVEX_TEST=1 source '$ct'; pvex_pack_files"
dies "entry without destination" -- env PVEX_FILES="$tmp/src/config.yaml" bash -c "PVEX_TEST=1 source '$ct'; pvex_pack_files"

echo "hook payload"
printf 'echo hi\n' >"$tmp/post.sh"
check "hook round-trips" "echo hi" "$(base64 -d <<<"$(pvex_pack_hook "$tmp/post.sh")")"
: >"$tmp/empty.sh"
dies "empty hook" -- bash -c "PVEX_TEST=1 source '$ct'; pvex_pack_hook '$tmp/empty.sh'"
big="$(head -c $((100 * 1024)) /dev/zero | tr '\0' a)"
dies "payload over the size cap" -- bash -c "PVEX_TEST=1 source '$ct'; pvex_check_payload PVEX_FILES '$big'"
(pvex_check_payload PVEX_FILES "short") && pass "small payload passes" || fail "small payload passes"

echo
if ((fails)); then
  echo "$fails failure(s)"
  exit 1
fi
echo "all passed"
