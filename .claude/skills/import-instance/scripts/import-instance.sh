#!/usr/bin/env bash
# Import a bare-metal cc-connect instance into the deploy repo as an agentbox instance. The source
# host is read only (collect.sh), the rendering is local (render.py), and the only place written is
# hosts/<host>/instances/<name>/ in the deploy repo. Secrets travel by rsync straight into that
# directory and never through stdout, stderr or this script's variables.
# Source connection comes from, in order of precedence: flags, environment variables, the skill's
# .env (../.env next to this script, gitignored; template in ../.env.example). The deploy repo path
# comes from --repo, AGENTBOX_DEPLOY_REPO, or the deploy skill's .env (shared variable, one truth).
# Exit codes: 0 ok / 1 usage error, target exists or remote failure / 2 precondition not met

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "${SKILL_DIR}/../../.." && pwd)"
DEPLOY_SKILL_DIR="${SKILL_DIR}/../deploy"

# Fill only what is still unset, so the environment and flags always win. A leading ~/ expands.
load_env_file() {
	local file="$1"; shift
	[ -f "${file}" ] || return 0
	local line name val
	while IFS= read -r line || [ -n "${line}" ]; do
		case "${line}" in ''|\#*) continue ;; esac
		name="${line%%=*}"; val="${line#*=}"
		case " $* " in *" ${name} "*) ;; *) continue ;; esac
		# shellcheck disable=SC2088  # matching a literal leading ~/ from the file is the point here
		case "${val}" in "~/"*) val="${HOME}/${val#\~/}" ;; esac
		[ -n "${!name:-}" ] || export "${name}=${val}"
	done < "${file}"
}
load_env_file "${SKILL_DIR}/.env" AGENTBOX_IMPORT_SOURCE AGENTBOX_IMPORT_KEY AGENTBOX_IMPORT_SOCKS AGENTBOX_IMPORT_HOST_KEY_ALIAS
load_env_file "${DEPLOY_SKILL_DIR}/.env" AGENTBOX_DEPLOY_REPO

SOURCE="${AGENTBOX_IMPORT_SOURCE:-}"
KEY="${AGENTBOX_IMPORT_KEY:-}"
SOCKS="${AGENTBOX_IMPORT_SOCKS:-}"
HOST_KEY_ALIAS="${AGENTBOX_IMPORT_HOST_KEY_ALIAS:-}"
REPO="${AGENTBOX_DEPLOY_REPO:-}"
IMAGE="ghcr.io/chinayin/agentbox"
LOCAL=0
ACTION=""
SRC_DIR=""
HOST=""
NAME=""
HOME_DIR=""
VERBOSE=0
DRY_RUN=0
declare -a SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new)

die()  { echo "Error: $*" >&2; exit 1; }
pre()  { echo "Error: $*" >&2; exit 2; }
warn() { echo "Warning: $*" >&2; }
step() { echo "==> $*" >&2; }
vlog() { [ "${VERBOSE}" -eq 1 ] && echo "verbose: $*" >&2 || true; }

usage() {
	cat <<'USAGE'
Usage: import-instance.sh [options] <action> <source-dir>

Actions:
  plan     read the source instance and print the migration plan; writes nothing
  import   plan, then write hosts/<host>/instances/<name>/ in the deploy repo and print the
           compose snippet; requires --host and --name

Arguments:
  <source-dir>   the instance directory holding config.toml and .env (on the source host, or a
                 local directory with --local)

Options:
      --source USER@HOST   source host (or AGENTBOX_IMPORT_SOURCE)
      --key PATH           SSH private key for the source host (or AGENTBOX_IMPORT_KEY)
      --socks HOST:PORT    SOCKS5 proxy for the source host (or AGENTBOX_IMPORT_SOCKS)
      --host-key-alias H   known_hosts alias, pairs with a <ip>.sslip.io host form
      --local              <source-dir> is a local directory; no connection is made
      --home DIR           owner's home directory on the source (default: derived from the owner
                           of config.toml); needed with --local
      --repo DIR           deploy repository (or AGENTBOX_DEPLOY_REPO, or the deploy skill .env)
      --host HOST          host directory in the deploy repo (hosts/<host> must already exist)
      --name NAME          instance name: [a-z][a-z0-9-]{0,31}
      --image REPO         image repository for the snippet (default ghcr.io/chinayin/agentbox)
      --dry-run            print what would run and what would be written; no connection, no files
  -v, --verbose            extra diagnostics on stderr (never a value from the source .env)
  -h, --help               show this help

Exit codes: 0 success / 1 usage error, target exists or remote failure / 2 precondition not met
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--source)          SOURCE="${2:?missing value}"; shift 2 ;;
		--key)             KEY="${2:?missing value}"; shift 2 ;;
		--socks)           SOCKS="${2:?missing value}"; shift 2 ;;
		--host-key-alias)  HOST_KEY_ALIAS="${2:?missing value}"; shift 2 ;;
		--local)           LOCAL=1; shift ;;
		--home)            HOME_DIR="${2:?missing value}"; shift 2 ;;
		--repo)            REPO="${2:?missing value}"; shift 2 ;;
		--host)            HOST="${2:?missing value}"; shift 2 ;;
		--name)            NAME="${2:?missing value}"; shift 2 ;;
		--image)           IMAGE="${2:?missing value}"; shift 2 ;;
		--dry-run)         DRY_RUN=1; shift ;;
		-v|--verbose)      VERBOSE=1; shift ;;
		-h|--help)         usage; exit 0 ;;
		--)                shift; break ;;
		-*)                usage >&2; die "unknown option: $1" ;;
		plan|import)       [ -z "${ACTION}" ] || { usage >&2; die "only one action is accepted"; }; ACTION="$1"; shift ;;
		*)                 [ -z "${SRC_DIR}" ] || { usage >&2; die "only one source directory is accepted"; }; SRC_DIR="$1"; shift ;;
	esac
done
[ $# -eq 0 ] || { [ -z "${SRC_DIR}" ] || { usage >&2; die "only one source directory is accepted"; }; SRC_DIR="$1"; }

[ -n "${ACTION}" ] || { usage >&2; die "an action is required: plan or import"; }
[ -n "${SRC_DIR}" ] || { usage >&2; die "<source-dir> is required"; }
if [ "${LOCAL}" -eq 0 ]; then
	[ -n "${SOURCE}" ] || { usage >&2; die "--source, AGENTBOX_IMPORT_SOURCE, or the skill .env is required (or pass --local)"; }
	[ -n "${KEY}" ] && SSH_OPTS+=(-i "${KEY}")
	# BSD nc SOCKS5 syntax; ssh substitutes %h %p.
	[ -n "${SOCKS}" ] && SSH_OPTS+=(-o "ProxyCommand=nc -X 5 -x ${SOCKS} %h %p")
	[ -n "${HOST_KEY_ALIAS}" ] && SSH_OPTS+=(-o "HostKeyAlias=${HOST_KEY_ALIAS}")
fi
if [ "${ACTION}" = import ]; then
	[ -n "${HOST}" ] || { usage >&2; die "import requires --host"; }
	[ -n "${NAME}" ] || { usage >&2; die "import requires --name"; }
	[[ "${NAME}" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "invalid name '${NAME}': use [a-z][a-z0-9-]{0,31}"
	[ -n "${REPO}" ] || { usage >&2; die "--repo, AGENTBOX_DEPLOY_REPO, or ${DEPLOY_SKILL_DIR}/.env is required for import"; }
	HOST_DIR="${REPO}/hosts/${HOST}"
	[ -f "${HOST_DIR}/host.env" ] || pre "host '${HOST}' not found in ${REPO} (expected ${HOST_DIR}/host.env; see .claude/skills/deploy/references/deploy-repo.md)"
	TARGET="${HOST_DIR}/instances/${NAME}"
fi
for t in ssh rsync python3; do
	[ "${LOCAL}" -eq 1 ] && [ "${t}" != python3 ] && continue
	command -v "${t}" >/dev/null 2>&1 || pre "${t} is required"
done

# Every command on the source goes through here; ssh's exit code passes through.
rssh() {
	vlog "ssh ${SOURCE}: $*"
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "plan: ssh ${SOURCE} -- $*" >&2
		return 0
	fi
	ssh "${SSH_OPTS[@]}" "${SOURCE}" "$@"
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

TMP="$(mktemp -d)"
chmod 0700 "${TMP}"
# shellcheck disable=SC2064  # expand TMP now, on purpose
trap "rm -rf '${TMP}'" EXIT

INVENTORY="${TMP}/inventory"
run_collect() {
	if [ "${LOCAL}" -eq 1 ]; then
		step "collecting from local directory ${SRC_DIR}"
		[ -n "${HOME_DIR}" ] || warn "--home not given; the owner's home will be derived, which usually fails off the source host"
		bash "${SKILL_DIR}/scripts/collect.sh" ${HOME_DIR:+--home "${HOME_DIR}"} "${SRC_DIR}" > "${INVENTORY}"
	else
		step "collecting from ${SOURCE}:${SRC_DIR} (read-only)"
		declare -a cargs=()
		[ -n "${HOME_DIR}" ] && cargs=(--home "${HOME_DIR}")
		# Every argument is shell-escaped with printf '%q' before it reaches the remote shell, so a
		# source directory or home path with a quote, space or shell metacharacter cannot break the
		# remote command line (or worse, run something unintended on the source host).
		local remote_cmd
		remote_cmd="bash -s --$(printf ' %q' "${cargs[@]+"${cargs[@]}"}" "${SRC_DIR}")"
		vlog "ssh ${SOURCE}: ${remote_cmd} < collect.sh"
		rssh "${remote_cmd}" < "${SKILL_DIR}/scripts/collect.sh" > "${INVENTORY}"
	fi
}
LOCKS=(--lock "${ROOT}/mise.lock" --lock "${ROOT}/mise.claude.lock" --lock "${ROOT}/mise.pi.lock")
run_render() {
	step "rendering the migration plan"
	declare -a hargs=()
	[ -n "${HOST}" ] && hargs=(--host "${HOST}")
	python3 "${SKILL_DIR}/scripts/render.py" --inventory "${INVENTORY}" "${LOCKS[@]}" --name "${NAME:-instance}" "${hargs[@]+"${hargs[@]}"}" --image "${IMAGE}"
}
# Fetch one path from the source into the target. kind: cred (file, 0600) / file / dir.
fetch() {
	local kind="$1" src="$2" dst="$3"
	vlog "fetch ${kind} ${src} -> ${dst}"
	install -d -m 0700 "$(dirname "${dst}")"
	if [ "${LOCAL}" -eq 1 ]; then
		if [ "${kind}" = dir ]; then cp -R "${src%/}/." "${dst}"; else cp "${src}" "${dst}"; fi
	else
		# Escape the remote path so a quote, space or shell metacharacter in it cannot break rsync's
		# remote-shell invocation.
		rsync -a -e "${TMP}/ssh" "${SOURCE}:$(printf '%q' "${src}")" "${dst}"
	fi
	[ "${kind}" = cred ] && chmod 600 "${dst}"
	return 0
}

do_import() {
	[ ! -e "${TARGET}" ] || die "${TARGET} already exists; remove it or pick another name"
	[ "${LOCAL}" -eq 1 ] || make_rsync_ssh "${TMP}/ssh"
	step "writing ${TARGET}"
	install -d -m 0700 "${TARGET}"
	trap 'rm -rf "${TARGET}"' ERR
	# .env first: rendering appends the lifted literals to it. It goes straight to disk.
	fetch cred "${SRC_DIR}/.env" "${TARGET}/env"
	python3 "${SKILL_DIR}/scripts/render.py" --inventory "${INVENTORY}" "${LOCKS[@]}" \
		--name "${NAME}" --host "${HOST}" --image "${IMAGE}" --out "${TARGET}" --copy-list "${TMP}/copies"
	local kind src dst n=0
	while IFS=$'\t' read -r kind src dst; do
		[ -n "${kind}" ] || continue
		fetch "${kind}" "${src}" "${TARGET}/${dst}"
		n=$((n + 1))
	done < "${TMP}/copies"
	step "imported ${NAME}: config.toml, env and ${n} credential/skill entries under ${TARGET}"
	echo "next: review env (chat app, proxy, kubeconfig set), paste the snippet into ${HOST_DIR}/docker-compose.yaml, commit, then: deploy.sh plan ${HOST} ${NAME}" >&2
	trap - ERR
}

# The one line both dry-run branches print for the collect step; kept as a single helper so the
# two actions cannot drift apart.
plan_collect_line() {
	if [ "${LOCAL}" -eq 1 ]; then echo "plan: bash collect.sh${HOME_DIR:+ --home ${HOME_DIR}} ${SRC_DIR} (local)" >&2
	else echo "plan: ssh ${SOURCE} -- bash -s -- ${SRC_DIR} < collect.sh" >&2; fi
}

case "${ACTION}" in
	plan)
		if [ "${DRY_RUN}" -eq 1 ]; then
			plan_collect_line
			echo "plan: render the migration plan to stdout" >&2
			exit 0
		fi
		run_collect; run_render ;;
	import)
		if [ "${DRY_RUN}" -eq 1 ]; then
			plan_collect_line
			echo "plan: write ${TARGET}/{config.toml,env} plus credential files and skill-lock.json (0600 for credentials)" >&2
			echo "plan: print the compose snippet for service '${NAME}' with image ${IMAGE}" >&2
			exit 0
		fi
		run_collect; do_import ;;
esac
