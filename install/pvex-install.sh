#!/usr/bin/env bash

# Copyright (c) 2026 jellyhuck
# License: MIT | https://github.com/jellyhuck/pvex/raw/main/LICENSE
# Source: https://github.com/jellyhuck/pvex
# Engine: https://github.com/community-scripts/core
#
# Generic installer: everything app-specific arrives as PVEX_* variables
# exported by ct/pvex.sh on the host (lxc-attach keeps the environment).

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Files of this repository: a local checkout when the engine was given one,
# otherwise the raw base the ct script resolved against.
pvex_fetch() {
  if [[ -n "${COMMUNITY_SCRIPTS_ROOT:-}" && -s "${COMMUNITY_SCRIPTS_ROOT}/$1" ]]; then
    cat "${COMMUNITY_SCRIPTS_ROOT}/$1"
  else
    curl -fsSL "${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/jellyhuck/pvex/main}/$1"
  fi
}
# shellcheck source=share/pvex-common.sh
source <(pvex_fetch share/pvex-common.sh)

if [[ -z "${PVEX_RUNNER:-}" || -z "${PVEX_PACKAGE:-}" ]]; then
  msg_error "PVEX_RUNNER and PVEX_PACKAGE are not set. Run this through ct/pvex.sh, which collects them."
  exit 1
fi

pvex_write_hooks() {
  install -d -m 0700 "$PVEX_HOOK_DIR"
  if [[ -n "${PVEX_PRE_B64:-}" ]]; then
    base64 -d <<<"$PVEX_PRE_B64" >"$PVEX_HOOK_DIR/pre.sh"
    chmod 0700 "$PVEX_HOOK_DIR/pre.sh"
  fi
  if [[ -n "${PVEX_POST_B64:-}" ]]; then
    base64 -d <<<"$PVEX_POST_B64" >"$PVEX_HOOK_DIR/post.sh"
    chmod 0700 "$PVEX_HOOK_DIR/post.sh"
  fi
}

pvex_create_user() {
  msg_info "Creating service user pvex"
  if pvex_is_alpine; then
    getent group pvex >/dev/null 2>&1 || $STD addgroup -S pvex
    id pvex >/dev/null 2>&1 || $STD adduser -S -D -H -h "$PVEX_HOME" -s /sbin/nologin -G pvex pvex
  else
    getent group pvex >/dev/null 2>&1 || $STD groupadd --system pvex
    id pvex >/dev/null 2>&1 || $STD useradd --system --gid pvex --home-dir "$PVEX_HOME" --shell /usr/sbin/nologin pvex
  fi
  install -d -o pvex -g pvex -m 0750 "$PVEX_HOME" "$PVEX_HOME/.cache"
  msg_ok "Created service user pvex"
}

pvex_write_conf() {
  msg_info "Writing /etc/pvex"
  install -d -m 0755 /etc/pvex
  {
    echo "# Written by pvex-install; edit and restart the pvex service, or run \`update\`."
    printf 'PVEX_RUNNER=%q\n' "$PVEX_RUNNER"
    printf 'PVEX_PACKAGE=%q\n' "$PVEX_PACKAGE"
    printf 'PVEX_COMMAND=%q\n' "${PVEX_COMMAND:-}"
    printf 'PVEX_ARGS=%q\n' "${PVEX_ARGS:-}"
    printf 'PVEX_PORT=%q\n' "${PVEX_PORT:-}"
    printf 'PVEX_PACKAGES=%q\n' "${PVEX_PACKAGES:-}"
    printf 'PVEX_NODE_VERSION=%q\n' "${PVEX_NODE_VERSION:-}"
    printf 'PVEX_PYTHON_VERSION=%q\n' "${PVEX_PYTHON_VERSION:-}"
    printf 'PVEX_BUN_VERSION=%q\n' "${PVEX_BUN_VERSION:-}"
    printf 'PVEX_RERUN_HOOKS=%q\n' "${PVEX_RERUN_HOOKS:-0}"
    # Only a ref the user chose is persisted: the default pin lives in ct/pvex.sh
    # so that bumping it there also moves existing containers on `update`.
    if [[ -n "${PVEX_CORE_REF:-}" ]]; then
      printf 'PVEX_CORE_REF=%q\n' "$PVEX_CORE_REF"
    fi
  } >"$PVEX_CONF"
  chmod 0644 "$PVEX_CONF"

  # Environment for the app only; pvex-run sources it, so every entry is
  # written as a quoted shell assignment whatever the value contains.
  {
    echo "# Environment for the app, loaded by pvex-run. One KEY='value' per line."
    local entry key value
    while IFS= read -r entry; do
      entry="${entry#"${entry%%[![:space:]]*}"}"
      entry="${entry%"${entry##*[![:space:]]}"}"
      [[ -z "$entry" || "$entry" == \#* ]] && continue
      key="${entry%%=*}"
      value="${entry#*=}"
      printf '%s=%q\n' "$key" "$value"
    done < <(pvex_env_entries)
  } >"$PVEX_ENV_FILE"
  chown root:pvex "$PVEX_ENV_FILE"
  chmod 0640 "$PVEX_ENV_FILE"

  pvex_install_wrapper
  msg_ok "Wrote /etc/pvex"
}

# One PVEX_ENV entry per line. A multi-line value is split on newlines only,
# so ';' inside a value survives; a single-line value is split on ';'.
pvex_env_entries() {
  [[ -n "${PVEX_ENV:-}" ]] || return 0
  if [[ "$PVEX_ENV" == *$'\n'* ]]; then
    printf '%s\n' "$PVEX_ENV"
  else
    tr ';' '\n' <<<"$PVEX_ENV"
  fi
}

pvex_place_files() {
  [[ -n "${PVEX_FILES_B64:-}" ]] || return 0
  msg_info "Placing configuration files"
  local tmp
  tmp="$(mktemp)"
  base64 -d <<<"$PVEX_FILES_B64" >"$tmp"
  # Directories that already exist keep their owner and mode: without
  # --no-overwrite-dir, tar run as root would reset /var/lib/pvex (0750, pvex)
  # or /tmp (1777) to the archive's 0755 root:root entries.
  tar -xzf "$tmp" --no-overwrite-dir -C /
  rm -f "$tmp"
  pvex_own_home
  msg_ok "Placed configuration files"
}

pvex_warmup() {
  if [[ "${PVEX_SKIP_CHECK:-0}" == 1 ]]; then
    msg_warn "PVEX_SKIP_CHECK=1: not resolving ${PVEX_PACKAGE} before the first start"
    return 0
  fi
  msg_info "Resolving ${PVEX_PACKAGE} with ${PVEX_RUNNER} (first download, may take a while)"
  if ! $STD su -s /bin/bash pvex -c "timeout 900 $PVEX_RUN_BIN --check"; then
    msg_error "${PVEX_RUNNER} could not resolve '${PVEX_PACKAGE}'. Check the spelling and version,"
    msg_error "or set PVEX_SKIP_CHECK=1 to install anyway and read the service log."
    exit 1
  fi
  msg_ok "Resolved ${PVEX_PACKAGE}"
}

# Unprivileged containers own their network namespace, so this sysctl is theirs
# to set. Only done when a low port was asked for.
pvex_allow_low_ports() {
  [[ -n "${PVEX_PORT:-}" && "$PVEX_PORT" -lt 1024 ]] || return 0
  echo "net.ipv4.ip_unprivileged_port_start=0" >/etc/sysctl.d/90-pvex.conf
  if ! sysctl -q -w net.ipv4.ip_unprivileged_port_start=0 2>/dev/null; then
    msg_warn "Could not lower net.ipv4.ip_unprivileged_port_start; port ${PVEX_PORT} may need root"
  fi
}

# The package is resolved (as the service user) before the post hook runs, so a
# hook calling `pvex-run --only --init` finds it downloaded; and the home is
# re-owned after the hook, which runs as root.
pvex_install_common() {
  pvex_write_hooks
  pvex_run_hook pre
  pvex_install_extra_packages
  pvex_create_user
  pvex_setup_runtime
  pvex_write_conf
  pvex_place_files
  pvex_warmup
  pvex_run_hook post
  pvex_own_home
}

setup_deb_based() {
  pvex_install_common

  msg_info "Creating Service"
  cat <<SERVICE >/etc/systemd/system/pvex.service
[Unit]
Description=pvex: ${PVEX_RUNNER} ${PVEX_PACKAGE}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pvex
Group=pvex
WorkingDirectory=${PVEX_HOME}
ExecStart=${PVEX_RUN_BIN}
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
SERVICE
  pvex_allow_low_ports
  systemctl enable -q --now pvex
  msg_ok "Created Service"
}

setup_alpine() {
  pvex_install_common

  msg_info "Creating Service"
  # Unquoted heredoc: the description is filled in, everything else is escaped.
  cat <<SERVICE >/etc/init.d/pvex
#!/sbin/openrc-run
name="pvex"
description="pvex: ${PVEX_RUNNER} ${PVEX_PACKAGE}"

# pvex-run loads /etc/pvex/app.env itself.
command="${PVEX_RUN_BIN}"
command_user="pvex:pvex"
supervisor=supervise-daemon
directory="${PVEX_HOME}"
output_log="/var/log/pvex.log"
error_log="/var/log/pvex.log"
respawn_delay=5

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath -f -m 0640 -o pvex:pvex "\$output_log"
}
SERVICE
  chmod +x /etc/init.d/pvex
  pvex_allow_low_ports
  $STD rc-update add pvex default
  $STD rc-service pvex start
  msg_ok "Created Service"
}

run_os_setup

motd_ssh
customize
cleanup_lxc
