#!/usr/bin/env bash
# A pvex post-install hook. It is sourced inside the install script as root,
# so the engine helpers (msg_info, msg_ok, $STD, setup_*), every PVEX_*
# variable and /usr/local/bin/pvex-run are available. `set -e` is on: a
# failing command fails the install.
#
# This example lets the app write its own default configuration once. The
# package is already downloaded at this point. pvex-run switches to the
# service user by itself and loads /etc/pvex/app.env; `--only` runs the app
# with just these arguments instead of PVEX_ARGS.

msg_info "Generating initial configuration"
install -d -o pvex -g pvex -m 0750 /var/lib/pvex/data
/usr/local/bin/pvex-run --only --init --data-dir /var/lib/pvex/data
msg_ok "Generated initial configuration"
