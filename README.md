# pvex

Deploy any `npx`, `bunx` or `uvx` app as a Proxmox VE LXC container, using the
[community-scripts](https://github.com/community-scripts/ProxmoxVE) engine. This
repo's script builds a small container for the package, runs it as a service,
and keeps it updatable with the usual `update` command.

## Minimal Example

Ever wanted to wrap `npx -y my-app` into an LXC container that you can simply
`update`?

On a Proxmox VE host:

```bash
PVEX_RUNNER=npx PVEX_PACKAGE=my-app PVEX_PORT=3000 \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/jellyhuck/pvex/main/ct/pvex.sh)"
```

The result is a container that runs `npx -y my-app` under systemd (Debian) or
OpenRC (Alpine), with `update` available inside it. `bunx` and `uvx` packages
work the same way.

## Usage

Without any variables the script asks for the runner and the package, then
hands over to the normal community-scripts wizard (container ID, hostname,
resources, network):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jellyhuck/pvex/main/ct/pvex.sh)"
```

Everything can also be given up front:

```bash
PVEX_RUNNER=uvx PVEX_PACKAGE=mcp-proxy PVEX_PORT=8096 PVEX_ARGS="--host 0.0.0.0 --port 8096" \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/jellyhuck/pvex/main/ct/pvex.sh)"
```

or kept in a spec file, which is just bash assignments (see
[`examples/`](examples/)):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jellyhuck/pvex/main/ct/pvex.sh)" -- ./mcp-proxy.pvex
```

## Variables

| Variable | Required | Meaning |
| --- | --- | --- |
| `PVEX_RUNNER` | yes | `npx`, `bunx` or `uvx` |
| `PVEX_PACKAGE` | yes | Package spec as the runner takes it: `my-app`, `@scope/my-app@1.2.3`, `my-tool==1.4.0`, `my-tool[extra]`, `git+https://…` |
| `PVEX_COMMAND` | no | Executable to run when it differs from the package name (`npx --package PKG -- CMD`, `bunx --package PKG CMD`, `uvx --from PKG CMD`) |
| `PVEX_ARGS` | no | Extra command-line arguments; quotes work (`--name 'My App'`) |
| `PVEX_PORT` | no | Port the app listens on. Shown in the final URL; a port below 1024 is made bindable for the unprivileged service user |
| `PVEX_ENV` | no | `KEY=VALUE` pairs for the app, written to `/etc/pvex/app.env`. A single line is split on `;`; a multi-line value is split on newlines only, so `;` inside a value survives |
| `PVEX_FILES` | no | Files to place in the container: `SRC:/absolute/dest` entries separated by `;` or newlines. `SRC` is a path on the Proxmox host or an `https://` URL. A `0600` source stays `0600` |
| `PVEX_PACKAGES` | no | Extra OS packages (`apt`/`apk`), space-separated, e.g. `ffmpeg sqlite3` |
| `PVEX_PRE_INSTALL` / `PVEX_POST_INSTALL` | no | Hook script (path or URL) run as root in the container before/after runtime, packages and files are set up, before the service exists. See [`examples/post-install.sh`](examples/post-install.sh) |
| `PVEX_RERUN_HOOKS` | no | `1` to run the hooks again on every `update` |
| `PVEX_NODE_VERSION` / `PVEX_PYTHON_VERSION` / `PVEX_BUN_VERSION` | no | Runtime versions (defaults: Node 24, uv's choice of Python, latest Bun) |
| `PVEX_SKIP_CHECK` | no | `1` to skip resolving the package during install |
| `PVEX_FILE` | no | Spec file to source first; the first command-line argument does the same |
| `PVEX_CORE_REF` | no | Commit or branch of [community-scripts/core](https://github.com/community-scripts/core) to run the engine from, instead of the pinned default |

Precedence: environment variables win over the spec file, and prompts only
appear when runner or package are still missing. `PHS_SILENT=1` suppresses
all prompts. The usual `var_*` knobs of the engine (`var_cpu`, `var_ram`,
`var_disk`, `var_os=alpine`, `var_hostname`, …) work as everywhere else; the
default hostname is `pvex-<package>`.

### Hooks and files

The installer is generic, so anything app-specific is injected rather than
edited in:

- Static configuration goes in with `PVEX_FILES`. Files under `/var/lib/pvex`
  end up owned by the service user, everything else by root.
- Generated configuration, extra directories, or anything the app's own CLI
  has to do once go in a `PVEX_POST_INSTALL` hook. Hooks are sourced inside
  the install script as root, with `set -e`, the engine's `msg_info`/`msg_ok`
  and `$STD` helpers, every `PVEX_*` variable and `pvex-run` available. The
  package is already downloaded when the post hook runs. `pvex-run -- ARGS`
  runs the app with `ARGS` added to `PVEX_ARGS`; `pvex-run --only ARGS` runs
  it with `ARGS` alone, e.g. `pvex-run --only --init`. Started as root,
  `pvex-run` switches to the `pvex` user by itself, so hooks need no `su`.
- Keep payloads small: files and hooks travel in the environment and are
  capped at 96 KiB each. Fetch anything bigger from a URL inside a hook.

## Examples

```bash
# A Node.js app that needs to listen on all interfaces
PVEX_RUNNER=npx PVEX_PACKAGE=my-web-app@2 PVEX_PORT=3000 PVEX_ARGS="--host 0.0.0.0" \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/jellyhuck/pvex/main/ct/pvex.sh)"

# A Bun app configured by environment variables, on Alpine
var_os=alpine PVEX_RUNNER=bunx PVEX_PACKAGE=my-bun-app PVEX_PORT=8080 PVEX_ENV="HOST=0.0.0.0;PORT=8080" \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/jellyhuck/pvex/main/ct/pvex.sh)"

# A Python tool whose executable name differs from the package
PVEX_RUNNER=uvx PVEX_PACKAGE="my-tool[server]==1.4.0" PVEX_COMMAND=my-tool-serve PVEX_PORT=9000 \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/jellyhuck/pvex/main/ct/pvex.sh)"
```

## Inside the container

| | Debian | Alpine |
| --- | --- | --- |
| Status | `systemctl status pvex` | `rc-service pvex status` |
| Restart | `systemctl restart pvex` | `rc-service pvex restart` |
| Logs | `journalctl -u pvex -f` | `tail -f /var/log/pvex.log` |
| Update | `update` | `update` |

Configuration lives in `/etc/pvex/pvex.conf` (runner, package, command,
arguments) and `/etc/pvex/app.env` (the app's environment, one shell-quoted
`KEY='value'` per line, loaded by `pvex-run` itself so systemd, OpenRC, hooks
and a manual `pvex-run` all see the same environment). Edit and restart the
service to change what runs; change the package pin there to move to a
specific version. The app runs as user `pvex` with home `/var/lib/pvex`, which
is where its data, the runner caches (`.npm`, `.bun/install/cache`,
`.cache/uv`, `.tmp`) and uv's managed Pythons (`.local/share/uv/python`) live.

## How it works

- `ct/pvex.sh` runs on the host. It collects the app spec, packs any files and
  hooks you named, exports everything as `PVEX_*` variables and starts the
  community-scripts engine, which creates the container and runs the installer
  inside it (the environment travels with `lxc-attach`).
- `install/pvex-install.sh` runs in the container. It installs the runtime
  (Node.js 24, Bun, or uv), creates the `pvex` user, writes
  `/etc/pvex/pvex.conf` and `/etc/pvex/app.env`, places your files, runs your
  hooks, resolves the package once so a typo fails the install rather than the
  service, and creates the service.
- The service runs `/usr/local/bin/pvex-run`, which reads `pvex.conf` and
  execs the runner, literally `npx -y PKG`, `bunx PKG` or `uvx PKG` plus your
  arguments. An unpinned package therefore follows its latest release on every
  restart; a pinned one (`my-app@1.2.3`, `my-tool==1.4`) stays put.
- `update` inside the container refreshes OS packages and the runtime, clears
  the runner's cache and restarts the service.

## Notes

- Apps that bind to `127.0.0.1` by default must be told to listen on
  `0.0.0.0` through `PVEX_ARGS` or `PVEX_ENV`, or they are unreachable from
  outside the container.
- The first start downloads the package, so it takes longer than later ones.
- pvex adds no authentication. Expose the container to a network you trust.
- Bun on Alpine uses the musl build; uv works on both. Node.js on Alpine comes
  from Alpine's own packages, so `PVEX_NODE_VERSION` applies to Debian only.

## Developing

```bash
bash tests/test-pvex-run.sh
bash tests/test-host-helpers.sh
shellcheck -x ct/pvex.sh install/pvex-install.sh share/pvex-common.sh bin/pvex-run tests/*.sh
```

A ct script fetched with `curl` cannot tell the engine where it came from, so
to test a branch of this repository point the engine at it explicitly:

```bash
export COMMUNITY_SCRIPTS_URL=https://raw.githubusercontent.com/jellyhuck/pvex/my-branch
bash -c "$(curl -fsSL "$COMMUNITY_SCRIPTS_URL/ct/pvex.sh")"
```

The engine itself is pinned to a commit of community-scripts/core in
`ct/pvex.sh` (`PVEX_CORE_DEFAULT_REF`); bumping it there moves new and, on
their next `update`, existing containers. `PVEX_CORE_REF=main` tries the
engine's current main.

## License

MIT. The engine is [community-scripts/core](https://github.com/community-scripts/core), also MIT.
