#!/usr/bin/env bash
# pvex — deploy an npx / bunx / uvx app as a Proxmox VE LXC container.
# https://github.com/jellyhuck/pvex
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jellyhuck/pvex/main/ct/pvex.sh)"
#   PVEX_RUNNER=uvx PVEX_PACKAGE=mcp-proxy PVEX_PORT=8096 bash -c "$(curl -fsSL …/ct/pvex.sh)"
#   bash -c "$(curl -fsSL …/ct/pvex.sh)" -- ./myapp.pvex
#
# Scripts root: install/pvex-install.sh, share/ and bin/ resolve against this,
# not against the URL this file was fetched from. Without it the engine looks
# in community-scripts/ProxmoxVE, which has no pvex.
_CS_DEFAULT_URL="https://raw.githubusercontent.com/jellyhuck/pvex/main"

# Engine pin. build.func reads _CS_CORE_DEFAULT_URL for every engine file it
# loads. PVEX_CORE_REF (a commit or branch of community-scripts/core) overrides
# the pin; COMMUNITY_SCRIPTS_CORE_URL / COMMUNITY_SCRIPTS_CORE_DIR, the engine's
# own knobs, override everything.
PVEX_CORE_DEFAULT_REF="09fac1952f6050395aae8e6ecc9d4900c5c180d2"
# The engine URL itself is resolved after the helper block below, once the
# spec file (host) or pvex.conf (container) has had its say on PVEX_CORE_REF.

# --- pvex host helpers --------------------------------------------------------
# Pure bash, no engine. tests/test-host-helpers.sh sources this file with
# PVEX_TEST=1 and stops right after this block.

pvex_die() {
  echo -e "\n  ✗ pvex: $*\n" >&2
  exit 1
}

# pvex_slug SPEC — a hostname label from a package spec:
#   @scope/my-app@1.2.3 -> my-app     my_tool==2.0 -> my-tool
#   git+https://github.com/o/repo.git -> repo
pvex_slug() {
  local s="$1"
  s="${s#git+}"
  case "$s" in
  http://* | https://* | ssh://* | git@*)
    s="${s%%[@#]*}"
    s="${s%/}"
    s="${s##*/}"
    s="${s%.git}"
    ;;
  *)
    s="${s#@}"      # npm scope marker
    s="${s##*/}"    # scope/name -> name
    s="${s%%@*}"    # npm version
    s="${s%%\[*}"   # python extras
    s="${s%%[=<>!~]*}" # python version specifier
    ;;
  esac
  s="${s,,}"
  s="${s//[^a-z0-9-]/-}"
  while [[ "$s" == *--* ]]; do s="${s//--/-}"; done
  s="${s#-}"
  s="${s%-}"
  printf '%s' "${s:0:50}"
}

# pvex_read_source SRC — prints a local file or an http(s) URL
pvex_read_source() {
  case "$1" in
  http://* | https://*) curl -fsSL "$1" ;;
  *)
    [[ -r "$1" ]] || return 1
    cat "$1"
    ;;
  esac
}

# pvex_pack_files — $PVEX_FILES ("SRC:DEST" entries, ';' or newline separated)
# becomes a base64 tar.gz rooted at / on stdout. The last ':' separates SRC from
# DEST so URLs work as sources.
pvex_pack_files() {
  local stage entry src dest
  stage="$(mktemp -d)"
  while IFS= read -r entry; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -z "$entry" ]] && continue
    dest="${entry##*:}"
    src="${entry%:*}"
    [[ "$src" != "$entry" && "$dest" == /* && "$dest" != */ ]] ||
      pvex_die "PVEX_FILES entry '${entry}' must be SRC:/absolute/destination"
    mkdir -p "${stage}$(dirname "$dest")"
    pvex_read_source "$src" >"${stage}${dest}" || pvex_die "PVEX_FILES: cannot read '${src}'"
    # a private source stays private; everything else is world-readable config
    if [[ -f "$src" && "$(stat -c %a "$src" 2>/dev/null)" =~ ^0?600$ ]]; then
      chmod 0600 "${stage}${dest}"
    else
      chmod 0644 "${stage}${dest}"
    fi
  done < <(tr ';' '\n' <<<"${PVEX_FILES:-}")
  # mktemp's 0700 must not travel: the archive's directory entries are applied
  # to /etc and friends when extracted as root.
  find "$stage" -type d -exec chmod 0755 {} +
  tar -C "$stage" --owner=0 --group=0 -czf - . | base64 -w0
  rm -rf "$stage"
}

# pvex_pack_hook SRC — a hook script as base64 on stdout
pvex_pack_hook() {
  local content
  content="$(pvex_read_source "$1")" || pvex_die "hook: cannot read '${1}'"
  [[ -n "$content" ]] || pvex_die "hook '${1}' is empty"
  base64 -w0 <<<"$content"
}

# pvex_check_payload NAME VALUE — one environment string is capped at 128 KiB
# by the kernel; leave headroom for the rest of the environment.
pvex_check_payload() {
  local max=$((96 * 1024))
  if ((${#2} > max)); then
    pvex_die "${1} is $((${#2} / 1024)) KiB after encoding; the limit is $((max / 1024)) KiB. Fetch large files from a URL in a hook instead."
  fi
}

# pvex_env_entries — one PVEX_ENV entry per line. A multi-line value is split
# on newlines only, so ';' inside a value survives; a single line splits on ';'.
# (install/pvex-install.sh carries the same function.)
pvex_env_entries() {
  [[ -n "${PVEX_ENV:-}" ]] || return 0
  if [[ "$PVEX_ENV" == *$'\n'* ]]; then
    printf '%s\n' "$PVEX_ENV"
  else
    tr ';' '\n' <<<"$PVEX_ENV"
  fi
}

pvex_validate() {
  case "${PVEX_RUNNER:-}" in
  npx | bunx | uvx) ;;
  *) pvex_die "PVEX_RUNNER must be npx, bunx or uvx (got '${PVEX_RUNNER:-}')" ;;
  esac
  [[ -n "${PVEX_PACKAGE:-}" ]] || pvex_die "PVEX_PACKAGE is required (e.g. my-app@1.2.3)"
  # Specs like 'litellm[proxy]>=1.0' are legitimate; the values are only ever
  # quoted (printf %q in pvex.conf, "$package" in pvex-run), so whitespace and
  # control characters are the only things to refuse.
  if [[ "${PVEX_PACKAGE}${PVEX_COMMAND:-}" =~ [[:space:][:cntrl:]] ]]; then
    pvex_die "PVEX_PACKAGE and PVEX_COMMAND may not contain whitespace"
  fi
  local entry
  while IFS= read -r entry; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -z "$entry" || "$entry" == \#* ]] && continue
    [[ "$entry" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] ||
      pvex_die "PVEX_ENV entry '${entry}' is not KEY=value"
  done < <(pvex_env_entries)
  if [[ -n "${PVEX_PORT:-}" ]] && ! [[ "$PVEX_PORT" =~ ^[0-9]{1,5}$ && "$PVEX_PORT" -le 65535 ]]; then
    pvex_die "PVEX_PORT must be a port number (got '${PVEX_PORT}')"
  fi
  if [[ -n "${PVEX_PACKAGES:-}" && "$PVEX_PACKAGES" =~ [^A-Za-z0-9+._[:space:]-] ]]; then
    pvex_die "PVEX_PACKAGES must be space-separated package names"
  fi
}

# pvex_load_spec_file PATH — a bash fragment setting PVEX_* and var_*
# variables. Values already in the environment win over the file.
pvex_load_spec_file() {
  local file="$1" saved="" v
  [[ -r "$file" ]] || pvex_die "spec file '${file}' not found"
  for v in $(compgen -e PVEX_ 2>/dev/null) $(compgen -e var_ 2>/dev/null); do
    # plain assignments: `declare` inside a function would make them local
    saved+="$(printf '%s=%q' "$v" "${!v}")"$'\n'
  done
  # shellcheck disable=SC1090
  source "$file" || pvex_die "spec file '${file}' failed to load"
  eval "$saved"
}

# pvex_ask VAR TITLE TEXT DEFAULT — whiptail input box on the host
pvex_ask() {
  local __var="$1" value
  value="$(whiptail --backtitle "pvex" --title "$2" --inputbox "$3" 11 72 "$4" 3>&1 1>&2 2>&3)" ||
    pvex_die "cancelled"
  printf -v "$__var" '%s' "$value"
}

pvex_prompt() {
  if [[ -z "${PVEX_RUNNER:-}" ]]; then
    # whiptail rather than the engine's msg_menu, which falls back to its first
    # entry after ten seconds; the runner is not a choice to make by timeout.
    PVEX_RUNNER="$(whiptail --backtitle "pvex" --title "Runner" --menu \
      "Which runner starts the app?" 13 72 3 \
      "npx" "Node.js package from the npm registry" \
      "bunx" "Bun package from the npm registry" \
      "uvx" "Python package from PyPI" 3>&1 1>&2 2>&3)" || pvex_die "cancelled"
  fi
  local hint
  case "$PVEX_RUNNER" in
  uvx) hint="PyPI package, optionally pinned: mcp-proxy, my-tool==1.4.0, git+https://…" ;;
  *) hint="npm package, optionally pinned: my-app, @scope/my-app@1.2.3" ;;
  esac
  [[ -n "${PVEX_PACKAGE:-}" ]] || pvex_ask PVEX_PACKAGE "Package" "$hint" ""
  [[ -n "${PVEX_PACKAGE:-}" ]] || pvex_die "a package is required"
  [[ -n "${PVEX_COMMAND+x}" ]] || pvex_ask PVEX_COMMAND "Command (optional)" \
    "Executable to run when it differs from the package name. Leave empty for the default." ""
  [[ -n "${PVEX_ARGS+x}" ]] || pvex_ask PVEX_ARGS "Arguments (optional)" \
    "Extra command-line arguments, e.g. --host 0.0.0.0 --port 8080" ""
  [[ -n "${PVEX_PORT+x}" ]] || pvex_ask PVEX_PORT "Port (optional)" \
    "Port the app listens on; shown in the final URL and used to allow ports below 1024." ""
  [[ -n "${PVEX_ENV+x}" ]] || pvex_ask PVEX_ENV "Environment (optional)" \
    "KEY=VALUE pairs separated by ';', e.g. HOST=0.0.0.0;LOG_LEVEL=info" ""
}

# --- end of host helpers ------------------------------------------------------

# A spec file may set PVEX_CORE_REF (and var_*), so it is read before the
# engine is chosen. Precedence: environment > spec file > prompts.
if [[ -n "${1:-}" && -z "${PVEX_FILE:-}" ]]; then
  PVEX_FILE="$1"
fi
[[ -n "${PVEX_FILE:-}" ]] && pvex_load_spec_file "$PVEX_FILE"

# `update` inside a container carries no PVEX_* environment; a ref the user
# chose at install time was persisted in pvex.conf.
if [[ -z "${PVEX_CORE_REF:-}" && -r /etc/pvex/pvex.conf ]] && ! command -v pveversion >/dev/null 2>&1; then
  PVEX_CORE_REF="$(sed -n 's/^PVEX_CORE_REF=//p' /etc/pvex/pvex.conf | tr -d "'\"")"
fi
_CS_CORE_DEFAULT_URL="https://raw.githubusercontent.com/community-scripts/core/${PVEX_CORE_REF:-$PVEX_CORE_DEFAULT_REF}"
# /usr/bin/update exports the engine URL the container was built with. Drop an
# upstream commit pin so that bumping the pin here also moves old containers;
# a fork or branch URL is a deliberate override and is kept.
if [[ "${COMMUNITY_SCRIPTS_CORE_URL:-}" =~ ^https://raw\.githubusercontent\.com/community-scripts/core/[0-9a-f]{40}$ ]]; then
  unset COMMUNITY_SCRIPTS_CORE_URL
fi

if [[ -n "${PVEX_TEST:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

if [[ -n "${COMMUNITY_SCRIPTS_CORE_DIR:-}" ]]; then
  source "${COMMUNITY_SCRIPTS_CORE_DIR}/core/build.func"
else
  # shellcheck disable=SC1090
  source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-$_CS_CORE_DEFAULT_URL}/core/build.func")
fi

# Copyright (c) 2026 jellyhuck
# License: MIT | https://github.com/jellyhuck/pvex/raw/main/LICENSE
# Source: https://github.com/jellyhuck/pvex
# Engine: https://github.com/community-scripts/core

APP="pvex"
# No banner in the engine's headers/ for an app outside upstream.
_CS_FALLBACK_HEADER='
   ____ _   _____  _  __
  / __ \ | / / _ \| |/_/
 / /_/ / |/ /  __/>  <
/ .___/|___/\___/_/|_|
/_/        npx · bunx · uvx → LXC'

if command -v pveversion >/dev/null 2>&1; then
  # On the host: collect the app spec (the spec file was loaded above).
  # Prompt only when the two required values are missing; a complete spec from
  # the environment or a file runs unattended.
  if [[ "${PHS_SILENT:-0}" != "1" && ( -z "${PVEX_RUNNER:-}" || -z "${PVEX_PACKAGE:-}" ) ]]; then
    pvex_prompt
  fi
  pvex_validate

  if [[ -n "${PVEX_FILES:-}" ]]; then
    PVEX_FILES_B64="$(pvex_pack_files)"
    pvex_check_payload PVEX_FILES "$PVEX_FILES_B64"
  fi
  if [[ -n "${PVEX_PRE_INSTALL:-}" ]]; then
    PVEX_PRE_B64="$(pvex_pack_hook "$PVEX_PRE_INSTALL")"
    pvex_check_payload PVEX_PRE_INSTALL "$PVEX_PRE_B64"
  fi
  if [[ -n "${PVEX_POST_INSTALL:-}" ]]; then
    PVEX_POST_B64="$(pvex_pack_hook "$PVEX_POST_INSTALL")"
    pvex_check_payload PVEX_POST_INSTALL "$PVEX_POST_B64"
  fi

  # lxc-attach keeps the environment, which is how these reach install/pvex-install.sh.
  export PVEX_RUNNER PVEX_PACKAGE PVEX_COMMAND PVEX_ARGS PVEX_PORT PVEX_ENV PVEX_PACKAGES
  export PVEX_NODE_VERSION PVEX_PYTHON_VERSION PVEX_BUN_VERSION
  export PVEX_FILES_B64 PVEX_PRE_B64 PVEX_POST_B64 PVEX_SKIP_CHECK PVEX_RERUN_HOOKS PVEX_CORE_REF

  _pvex_slug="$(pvex_slug "$PVEX_PACKAGE")"
  var_hostname="${var_hostname:-pvex${_pvex_slug:+-$_pvex_slug}}"
fi

var_tags="${var_tags:-pvex${PVEX_RUNNER:+;$PVEX_RUNNER}}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-4}"
var_unprivileged="${var_unprivileged:-1}"

if [[ -z "${var_os:-}" ]] && command -v pveversion >/dev/null 2>&1; then
  var_os=$(msg_menu "Choose the container OS" \
    "debian" "Debian 13" \
    "alpine" "Alpine 3.24 (smaller)")
fi

var_os="${var_os:-debian}"
if [[ "${var_os}" == "alpine" ]]; then
  var_version="${var_version:-3.24}"
else
  var_version="${var_version:-13}"
fi

header_info "$APP"
variables
color
catch_errors

# Files of this repository, for update_script() inside the container.
pvex_fetch() {
  if [[ -n "${COMMUNITY_SCRIPTS_ROOT:-}" && -s "${COMMUNITY_SCRIPTS_ROOT}/$1" ]]; then
    cat "${COMMUNITY_SCRIPTS_ROOT}/$1"
  else
    curl -fsSL "${COMMUNITY_SCRIPTS_URL:-$_CS_DEFAULT_URL}/$1"
  fi
}

# An unpinned package is re-resolved by the runner on every start, so an update
# is: refresh the OS and runtime, drop the runner cache, restart. A pinned
# package stays pinned; edit /etc/pvex/pvex.conf to move it.
pvex_update_common() {
  # shellcheck source=share/pvex-common.sh
  source <(pvex_fetch share/pvex-common.sh)
  if [[ "${PVEX_RERUN_HOOKS:-0}" == "1" ]]; then
    pvex_run_hook pre
  fi
  pvex_install_extra_packages
  pvex_setup_runtime
  pvex_install_wrapper
  if [[ "${PVEX_RERUN_HOOKS:-0}" == "1" ]]; then
    pvex_run_hook post
  fi

  msg_info "Restarting ${APP} (${PVEX_RUNNER} ${PVEX_PACKAGE})"
  pvex_service stop
  pvex_clear_cache
  pvex_service start
  msg_ok "Restarted ${APP}"
}

update_deb_based() {
  msg_info "Updating OS packages"
  $STD apt-get update
  $STD apt-get -y upgrade
  msg_ok "Updated OS packages"
  pvex_update_common
}

update_alpine() {
  msg_info "Updating Alpine packages"
  $STD apk -U upgrade
  msg_ok "Updated Alpine packages"
  pvex_update_common
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -r /etc/pvex/pvex.conf ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  # shellcheck disable=SC1091
  source /etc/pvex/pvex.conf

  run_os_update
  msg_ok "Updated successfully!"
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Running:${CL} ${PVEX_RUNNER} ${PVEX_PACKAGE}${PVEX_COMMAND:+ (command: $PVEX_COMMAND)}${PVEX_ARGS:+ $PVEX_ARGS}"
if [[ -n "${PVEX_PORT:-}" ]]; then
  echo -e "${INFO}${YW}Access it using the following URL:${CL}"
  echo -e "${GATEWAY}${BGN}http://${IP}:${PVEX_PORT}${CL}"
else
  echo -e "${INFO}${YW}Container IP:${CL} ${BGN}${IP}${CL}"
fi
if [[ "${var_os}" == "alpine" ]]; then
  echo -e "${INFO}${YW}Service: rc-service pvex status · Logs: tail -f /var/log/pvex.log${CL}"
else
  echo -e "${INFO}${YW}Service: systemctl status pvex · Logs: journalctl -u pvex -f${CL}"
fi
echo -e "${INFO}${YW}Config: /etc/pvex/pvex.conf and /etc/pvex/app.env; run 'update' in the container to refresh.${CL}"
