#!/usr/bin/env bash
# Functions shared by install/pvex-install.sh (first install) and the
# update_script() in ct/pvex.sh (every later `update`). Sourced inside the
# container after the engine, so msg_info/msg_ok/msg_warn/msg_error, $STD and
# the setup_* helpers from community-scripts/core are available.
#
# The caller must define pvex_fetch REL_PATH, which prints a file from this
# repository (local checkout or raw GitHub), and must have sourced
# /etc/pvex/pvex.conf or exported the PVEX_* variables.

# shellcheck disable=SC2034 # the install script and hooks use these
PVEX_HOME="/var/lib/pvex"
PVEX_CONF="/etc/pvex/pvex.conf"
PVEX_ENV_FILE="/etc/pvex/app.env"
PVEX_HOOK_DIR="/etc/pvex/hooks"
PVEX_BUN_INSTALL="/opt/bun"
PVEX_UV_PYTHON_DIR="/var/lib/pvex/.local/share/uv/python"
PVEX_RUN_BIN="/usr/local/bin/pvex-run"

pvex_is_alpine() { [[ -f /etc/alpine-release ]]; }

# pvex_pkg_install PKG... — OS packages, whichever package manager this is
pvex_pkg_install() {
  if pvex_is_alpine; then
    $STD apk add --no-cache "$@"
  else
    $STD apt-get install -y "$@"
  fi
}

pvex_install_extra_packages() {
  [[ -n "${PVEX_PACKAGES:-}" ]] || return 0
  msg_info "Installing extra packages: ${PVEX_PACKAGES}"
  # shellcheck disable=SC2086 # word splitting is the point
  pvex_pkg_install ${PVEX_PACKAGES}
  msg_ok "Installed extra packages"
}

pvex_setup_node() {
  if pvex_is_alpine; then
    # setup_nodejs is apt-only; Alpine's own package is current enough for npx.
    msg_info "Installing Node.js"
    $STD apk add --no-cache nodejs npm
    msg_ok "Installed Node.js $(node --version)"
  else
    NODE_VERSION="${PVEX_NODE_VERSION:-24}" setup_nodejs
  fi
}

# Bun ships no apt/apk package and the engine has no helper; take the release
# zip for this CPU and libc. PVEX_BUN_VERSION pins a release (e.g. 1.2.20).
pvex_setup_bun() {
  local arch url tmp tag
  case "$(uname -m)" in
  x86_64) arch="x64" ;;
  aarch64) arch="aarch64" ;;
  *)
    msg_error "Bun has no build for $(uname -m)"
    return 1
    ;;
  esac
  if pvex_is_alpine; then
    arch="${arch}-musl"
  fi
  # The default x64 build needs AVX2; older CPUs get the baseline build.
  if [[ "$arch" == x64* ]] && ! grep -q avx2 /proc/cpuinfo; then
    arch="${arch}-baseline"
  fi
  if [[ -n "${PVEX_BUN_VERSION:-}" ]]; then
    tag="${PVEX_BUN_VERSION#bun-}"
    tag="bun-v${tag#v}" # accepts 1.2.20, v1.2.20 and bun-v1.2.20
    url="https://github.com/oven-sh/bun/releases/download/${tag}/bun-linux-${arch}.zip"
  else
    url="https://github.com/oven-sh/bun/releases/latest/download/bun-linux-${arch}.zip"
  fi

  msg_info "Installing Bun"
  if pvex_is_alpine; then
    pvex_pkg_install libstdc++ libgcc unzip
  else
    pvex_pkg_install unzip
  fi
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/bun.zip" "$url"
  unzip -oq "$tmp/bun.zip" -d "$tmp"
  install -d -m 0755 "$PVEX_BUN_INSTALL/bin"
  install -m 0755 "$tmp"/bun-linux-*/bun "$PVEX_BUN_INSTALL/bin/bun"
  ln -sf "$PVEX_BUN_INSTALL/bin/bun" /usr/local/bin/bun
  ln -sf "$PVEX_BUN_INSTALL/bin/bun" /usr/local/bin/bunx
  rm -rf "$tmp"
  msg_ok "Installed Bun $(bun --version)"
}

pvex_setup_uv() {
  # A system Python saves uv a download on first start; Debian templates ship one.
  if pvex_is_alpine; then
    msg_info "Installing Python"
    $STD apk add --no-cache python3
    msg_ok "Installed Python $(python3 --version | cut -d' ' -f2)"
  fi
  # setup_uv runs `uv python install` as root; without this it would land in
  # /root/.local, where the service user cannot read it. pvex-run points uvx at
  # the same directory.
  export UV_PYTHON_INSTALL_DIR="$PVEX_UV_PYTHON_DIR"
  install -d -m 0755 "$PVEX_UV_PYTHON_DIR"
  # setup_uv installs /usr/local/bin/uv only. The Debian engine adds a uvx
  # wrapper when USE_UVX=YES; the Alpine engine has no such option.
  export USE_UVX=YES
  if [[ -n "${PVEX_PYTHON_VERSION:-}" ]]; then
    PYTHON_VERSION="$PVEX_PYTHON_VERSION" setup_uv
  else
    setup_uv
  fi
  pvex_ensure_uvx
  pvex_own_home
}

# pvex-run execs `uvx`, which is `uv tool run`. Whichever engine installed uv,
# make sure a uvx exists where pvex-run's PATH (not root's) will find it.
pvex_ensure_uvx() {
  local uvx="/usr/local/bin/uvx"
  if [[ -x "$uvx" || -x /usr/bin/uvx ]]; then
    return 0
  fi
  if [[ ! -x /usr/local/bin/uv ]]; then
    msg_error "uv is not installed in /usr/local/bin; cannot provide uvx"
    return 1
  fi
  msg_info "Installing uvx wrapper"
  cat >"$uvx" <<'EOF_UVX'
#!/bin/sh
# uvx: `uv tool run`, for engines that install uv without it. Written by pvex.
exec /usr/local/bin/uv tool run "$@"
EOF_UVX
  chmod 0755 "$uvx"
  msg_ok "Installed uvx wrapper"
}

# Everything under the service user's home belongs to the service user. The
# installer and hooks run as root, so this is called after each step that may
# have written there.
pvex_own_home() {
  id pvex >/dev/null 2>&1 || return 0
  chown -R pvex:pvex "$PVEX_HOME"
}

pvex_setup_runtime() {
  case "${PVEX_RUNNER:-}" in
  npx) pvex_setup_node ;;
  bunx) pvex_setup_bun ;;
  uvx) pvex_setup_uv ;;
  *)
    msg_error "Unknown runner '${PVEX_RUNNER:-}' (expected npx, bunx or uvx)"
    return 1
    ;;
  esac
}

# The wrapper is fetched from this repository rather than embedded, so one copy
# exists and `update` picks up fixes.
pvex_install_wrapper() {
  local tmp
  tmp="$(mktemp)"
  pvex_fetch bin/pvex-run >"$tmp" || {
    msg_error "Could not fetch bin/pvex-run"
    rm -f "$tmp"
    return 1
  }
  bash -n "$tmp" || {
    msg_error "Fetched bin/pvex-run does not parse"
    rm -f "$tmp"
    return 1
  }
  install -m 0755 "$tmp" "$PVEX_RUN_BIN"
  rm -f "$tmp"
}

# The runners cache under the service user's home (pvex-run points each of
# them there); dropping those caches is what makes the next start re-resolve
# an unpinned package. Managed Pythons are kept.
pvex_clear_cache() {
  rm -rf "$PVEX_HOME/.npm/_npx" "$PVEX_HOME/.bun/install/cache" "$PVEX_HOME/.cache/uv" "$PVEX_HOME/.tmp"
}

# pvex_run_hook pre|post — runs /etc/pvex/hooks/<name>.sh inside this shell
# (as root, with msg_*, $STD and every PVEX_* variable), so a hook can use the
# same helpers an install script does. A failing hook fails the install.
pvex_run_hook() {
  local name="$1" hook="$PVEX_HOOK_DIR/$1.sh"
  [[ -s "$hook" ]] || return 0
  msg_info "Running ${name}-install hook"
  # shellcheck disable=SC1090
  (
    set -e
    source "$hook"
  ) || {
    msg_error "${name}-install hook failed (${hook})"
    return 1
  }
  msg_ok "Ran ${name}-install hook"
}

# pvex_service start|stop|restart|status
pvex_service() {
  if pvex_is_alpine; then
    $STD rc-service pvex "$1"
  else
    systemctl "$1" pvex
  fi
}
