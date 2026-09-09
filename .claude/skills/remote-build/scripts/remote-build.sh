#!/usr/bin/env bash
# Dev helper, not a release path: rsync the repo to a docker host with good egress, run
# make image / make smoke there, pull the log back. Secrets and env files are never synced.
# Target comes from, in order of precedence: flags, environment variables, the skill's .env file
# (../.env next to this script, gitignored; template in ../.env.example). No host addresses live
# in this file. Variables: AGENTBOX_REMOTE (user@host), AGENTBOX_REMOTE_KEY, AGENTBOX_REMOTE_DIR
# (/data/agentbox), AGENTBOX_REMOTE_SOCKS (host:port), AGENTBOX_REMOTE_HOST_KEY_ALIAS.
# Rule-based proxies (Clash) send bare IPs DIRECT: with --socks use the <ip>.sslip.io hostname form
# plus --host-key-alias <ip> so the connection really goes via the proxy.
# Exit codes: 0 ok / 1 usage or remote failure / 2 precondition (unreachable, missing ssh/rsync/docker)

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "${SKILL_DIR}/../../.." && pwd)"

# .env fills only variables that are still unset, so the environment and flags always win.
# A leading ~/ in a value is expanded; nothing else is interpreted.
if [ -f "${SKILL_DIR}/.env" ]; then
	while IFS= read -r line || [ -n "${line}" ]; do
		case "${line}" in ''|\#*) continue ;; esac
		name="${line%%=*}"; val="${line#*=}"
		case "${name}" in AGENTBOX_REMOTE|AGENTBOX_REMOTE_KEY|AGENTBOX_REMOTE_DIR|AGENTBOX_REMOTE_SOCKS|AGENTBOX_REMOTE_HOST_KEY_ALIAS) ;; *) continue ;; esac
		# shellcheck disable=SC2088  # matching a literal leading ~/ from the file is the point here
		case "${val}" in "~/"*) val="${HOME}/${val#\~/}" ;; esac
		[ -n "${!name:-}" ] || export "${name}=${val}"
	done < "${SKILL_DIR}/.env"
fi

REMOTE="${AGENTBOX_REMOTE:-}"
KEY="${AGENTBOX_REMOTE_KEY:-}"
REMOTE_DIR="${AGENTBOX_REMOTE_DIR:-/data/agentbox}"
SOCKS="${AGENTBOX_REMOTE_SOCKS:-}"
HOST_KEY_ALIAS="${AGENTBOX_REMOTE_HOST_KEY_ALIAS:-}"
PLATFORM=""
LOG_DIR="${ROOT}/runtime/remote-build"
ACTION="build"
VERBOSE=0
DRY_RUN=0
declare -a SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new)

die()  { echo "Error: $*" >&2; exit 1; }
warn() { echo "Warning: $*" >&2; }
step() { echo "==> $*" >&2; }
vlog() { [ "${VERBOSE}" -eq 1 ] && echo "verbose: $*" >&2 || true; }

usage() {
	cat <<'USAGE'
Usage: remote-build.sh [options] [action]

Actions:
  sync       only sync the repo to the remote
  build      sync and build both images (default)
  smoke      sync, build and run make smoke
  shell      sync, then open an interactive remote shell in the remote repo directory
  probe      only check remote reachability, docker and egress

Options:
      --remote USER@HOST   target host (or the AGENTBOX_REMOTE environment variable)
      --key PATH           SSH private key (or the AGENTBOX_REMOTE_KEY environment variable)
      --dir PATH           remote working directory (default /data/agentbox)
      --socks HOST:PORT    connect through a SOCKS5 proxy (or AGENTBOX_REMOTE_SOCKS)
      --host-key-alias H   record the host key under this alias in known_hosts (pairs with a
                           hostname form such as <ip>.sslip.io)
      --platform VALUE     cross-build platform, passed to make PLATFORM= (unset by default)
      --dry-run            only print the commands that would run
  -v, --verbose            extra diagnostics (to stderr)
  -h, --help               show this help

Defaults for --remote/--key/--dir/--socks/--host-key-alias can live in the skill's .env file
(.claude/skills/remote-build/.env, gitignored; copy .env.example). Flags and environment win.

Build logs are written to runtime/remote-build/<timestamp>-<action>.log under the repo root;
runtime/ holds every local artifact and is already ignored by git and docker.

Exit codes: 0 success / 1 usage error or remote command failure / 2 precondition not met
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--remote)   REMOTE="${2:?missing value}"; shift 2 ;;
		--key)      KEY="${2:?missing value}"; shift 2 ;;
		--dir)      REMOTE_DIR="${2:?missing value}"; shift 2 ;;
		--socks)    SOCKS="${2:?missing value}"; shift 2 ;;
		--host-key-alias) HOST_KEY_ALIAS="${2:?missing value}"; shift 2 ;;
		--platform) PLATFORM="${2:?missing value}"; shift 2 ;;
		--dry-run)  DRY_RUN=1; shift ;;
		-v|--verbose) VERBOSE=1; shift ;;
		-h|--help)  usage; exit 0 ;;
		--)         shift; break ;;
		-*)         usage >&2; die "unknown option: $1" ;;
		sync|build|smoke|shell|probe) ACTION="$1"; shift ;;
		*)          usage >&2; die "unknown action: $1" ;;
	esac
done

[ -n "${REMOTE}" ] || { usage >&2; die "--remote, AGENTBOX_REMOTE, or AGENTBOX_REMOTE in ${SKILL_DIR}/.env is required"; }
[ -n "${KEY}" ] && SSH_OPTS+=(-i "${KEY}")
# BSD nc SOCKS5 syntax; ssh substitutes %h %p.
[ -n "${SOCKS}" ] && SSH_OPTS+=(-o "ProxyCommand=nc -X 5 -x ${SOCKS} %h %p")
[ -n "${HOST_KEY_ALIAS}" ] && SSH_OPTS+=(-o "HostKeyAlias=${HOST_KEY_ALIAS}")

for t in ssh rsync; do
	command -v "${t}" >/dev/null 2>&1 || { echo "Error: ${t} is required" >&2; exit 2; }
done

# All remote commands go through here; ssh exit code passes through.
rssh() {
	vlog "ssh ${REMOTE}: $*"
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "plan: ssh ${REMOTE} -- $*" >&2
		return 0
	fi
	ssh "${SSH_OPTS[@]}" "${REMOTE}" "$@"
}

probe() {
	step "probing remote ${REMOTE}"
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "plan: ssh ${REMOTE} -- probe (host, docker, egress)" >&2
		return 0
	fi
	if ! ssh "${SSH_OPTS[@]}" "${REMOTE}" true 2>/dev/null; then
		echo "Error: cannot reach ${REMOTE} over SSH" >&2
		if [ -n "${SOCKS}" ]; then
			# Suggesting --socks here would be advice to keep doing what just failed. A proxy that
			# stops routing to this host looks exactly like an unreachable host, and the direct
			# path may well be working: 2026-09-09 the Clash SOCKS path timed out during banner
			# exchange while a direct connection succeeded.
			echo "  the SOCKS proxy ${SOCKS} is in use; try again without it (comment out" >&2
			echo "  AGENTBOX_REMOTE_SOCKS in ${SKILL_DIR}/.env) to see whether the direct path works" >&2
		else
			echo "  check the security group, the port and the key; if direct return traffic is" >&2
			echo "  dropped, set AGENTBOX_REMOTE_SOCKS or pass --socks" >&2
		fi
		exit 2
	fi
	rssh 'set -e
		echo "host: $(hostname) $(uname -m)"
		. /etc/os-release && echo "os: ${PRETTY_NAME}"
		command -v docker >/dev/null || { echo "Error: no docker on the remote" >&2; exit 2; }
		echo "docker: $(docker --version)"
		docker buildx version 2>/dev/null | head -1 || echo "Warning: no buildx; BuildKit secret/--mount may be unavailable" >&2
		echo "CPU: $(nproc)  mem: $(free -g | awk "/Mem/{print \$2}")G  disk: $(df -h / | awk "NR==2{print \$4}") free"
		for u in https://github.com https://dl.google.com/go/ https://nodejs.org/dist/ https://get.helm.sh/ https://dl.k8s.io/ https://mirrors.aliyun.com/debian/ https://deb.debian.org/debian/ https://npmmirror.com/mirrors/node/; do
			printf "%-45s " "$u"; curl -sS -m 10 -o /dev/null -w "%{http_code} %{time_total}s\n" "$u" || echo "FAIL"
		done'
}

# rsync -e takes one string; options with spaces (ProxyCommand) need a wrapper script.
make_rsync_ssh() {
	local wrapper="$1" opt
	{
		echo '#!/usr/bin/env bash'
		printf 'exec ssh'
		for opt in "${SSH_OPTS[@]}"; do printf ' %q' "${opt}"; done
		echo ' "$@"'
	} > "${wrapper}"
	chmod 0700 "${wrapper}"
}

sync_repo() {
	step "syncing repo to ${REMOTE}:${REMOTE_DIR}"
	local tmp
	tmp="$(mktemp -d)"
	# shellcheck disable=SC2064  # expand tmp now, on purpose
	trap "rm -rf '${tmp}'" RETURN
	make_rsync_ssh "${tmp}/ssh"
	local -a args=(-az --delete
		--exclude '.git/' --exclude 'runtime/' --exclude '.codegraph/'
		--exclude 'examples/*/env' --exclude '.env' --exclude '.claude/skills/*/.env'
		--exclude '*.bak' --exclude '.DS_Store')
	[ "${VERBOSE}" -eq 1 ] && args+=(-v)
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "plan: rsync ${args[*]} ${ROOT}/ ${REMOTE}:${REMOTE_DIR}/" >&2
		return 0
	fi
	rssh "install -d -m 0755 '${REMOTE_DIR}'"
	rsync "${args[@]}" -e "${tmp}/ssh" "${ROOT}/" "${REMOTE}:${REMOTE_DIR}/"
}

# Run make remotely, tee the log locally, return make's exit code.
remote_make() {
	local target="$1"
	local ts log
	ts="$(date +%Y%m%d-%H%M%S)"
	log="${LOG_DIR}/${ts}-${target}.log"
	install -d -m 0755 "${LOG_DIR}"
	step "running make ${target}${PLATFORM:+ PLATFORM=${PLATFORM}} on the remote (log: ${log})"
	local cmd="cd '${REMOTE_DIR}' && DOCKER_BUILDKIT=1 BUILDKIT_PROGRESS=plain make ${target}"
	[ -n "${PLATFORM}" ] && cmd="${cmd} PLATFORM='${PLATFORM}'"
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "plan: ssh ${REMOTE} -- ${cmd}" >&2
		return 0
	fi
	local rc=0
	ssh "${SSH_OPTS[@]}" "${REMOTE}" "${cmd}" 2>&1 | tee "${log}" || rc=$?
	if [ "${rc}" -ne 0 ]; then
		echo "Error: remote make ${target} failed (rc=${rc}); full log at ${log}" >&2
		return 1
	fi
	echo "${log}"
}

main() {
	case "${ACTION}" in
		probe) probe ;;
		sync)  probe >/dev/null; sync_repo ;;
		build) probe >/dev/null; sync_repo; remote_make image ;;
		smoke) probe >/dev/null; sync_repo; remote_make image >/dev/null; remote_make smoke ;;
		shell)
			probe >/dev/null; sync_repo
			[ "${DRY_RUN}" -eq 1 ] && exit 0
			exec ssh "${SSH_OPTS[@]}" -t "${REMOTE}" "cd '${REMOTE_DIR}' && exec bash -l"
			;;
	esac
}

main
