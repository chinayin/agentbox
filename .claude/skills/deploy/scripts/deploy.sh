#!/usr/bin/env bash
# Publish agentbox instances to a remote docker host. Configuration and secrets come from a
# separate private deploy repository, one directory per host; images come from GHCR by version.
# The repo path comes from, in order of precedence: --repo, AGENTBOX_DEPLOY_REPO, the skill's .env
# file (../.env next to this script, gitignored; template in ../.env.example).
# Per-host connection details live in the deploy repo at hosts/<host>/host.env and never in here.
# Exit codes: 0 ok / 1 usage error or remote failure / 2 precondition (unreachable, missing tools)

# shellcheck disable=SC2034  # LOG_DIR/DRY_RUN are consumed once later tasks add the
# plan/deploy/status bodies; this skeleton only parses and stores them.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "${SKILL_DIR}/../../.." && pwd)"

# .env fills only variables that are still unset, so the environment and flags always win.
# A leading ~/ in a value is expanded; nothing else is interpreted.
if [ -f "${SKILL_DIR}/.env" ]; then
	while IFS= read -r line || [ -n "${line}" ]; do
		case "${line}" in ''|\#*) continue ;; esac
		name="${line%%=*}"; val="${line#*=}"
		case "${name}" in AGENTBOX_DEPLOY_REPO) ;; *) continue ;; esac
		# shellcheck disable=SC2088  # matching a literal leading ~/ from the file is the point here
		case "${val}" in "~/"*) val="${HOME}/${val#\~/}" ;; esac
		[ -n "${!name:-}" ] || export "${name}=${val}"
	done < "${SKILL_DIR}/.env"
fi

REPO="${AGENTBOX_DEPLOY_REPO:-}"
LOG_DIR="${ROOT}/runtime/deploy"
ACTION=""
HOST=""
INSTANCE=""
FORCE=0
VERBOSE=0
DRY_RUN=0

die()  { echo "错误: $*" >&2; exit 1; }
pre()  { echo "错误: $*" >&2; exit 2; }
warn() { echo "警告: $*" >&2; }
step() { echo "==> $*" >&2; }
vlog() { [ "${VERBOSE}" -eq 1 ] && echo "verbose: $*" >&2 || true; }

usage() {
	cat <<'USAGE'
Usage: deploy.sh [options] <action> [host] [instance]

Actions:
  plan     HOST [INSTANCE]   validate locally and print the impact; never connects
  deploy   HOST [INSTANCE]   push config and secrets, pull the image, start containers
  status   HOST              remote container state and recent logs

Options:
      --repo PATH    deploy repository (or the AGENTBOX_DEPLOY_REPO environment variable)
      --force        proceed even though the deploy repo has uncommitted changes
      --dry-run      only print the commands that would run
  -v, --verbose      extra diagnostics (to stderr)
  -h, --help         show this help

The deploy repo path can live in the skill's .env file (.claude/skills/deploy/.env, gitignored;
copy .env.example). Flags and environment win. Per-host connection details and the target image
version live in the deploy repo at hosts/<host>/host.env.

Deploy logs are written to runtime/deploy/<timestamp>-<action>-<host>.log under the repo root.

Exit codes: 0 success / 1 usage error or remote command failure / 2 precondition not met
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)  REPO="${2:?missing value}"; shift 2 ;;
		--force) FORCE=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-v|--verbose) VERBOSE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*) usage >&2; die "unknown option: $1" ;;
		plan|deploy|status)
			[ -n "${ACTION}" ] && { usage >&2; die "only one action is allowed"; }
			ACTION="$1"; shift ;;
		*)
			if [ -z "${ACTION}" ]; then usage >&2; die "unknown action: $1"; fi
			if   [ -z "${HOST}" ];     then HOST="$1"
			elif [ -z "${INSTANCE}" ]; then INSTANCE="$1"
			else usage >&2; die "unexpected argument: $1"; fi
			shift ;;
	esac
done

[ -n "${ACTION}" ] || { usage >&2; die "an action is required"; }
[ -n "${REPO}" ]   || { usage >&2; die "--repo, AGENTBOX_DEPLOY_REPO, or AGENTBOX_DEPLOY_REPO in ${SKILL_DIR}/.env is required"; }
[ -d "${REPO}" ]   || die "deploy repo ${REPO} is not a directory"
[ -n "${HOST}" ]   || { usage >&2; die "a host is required"; }

HOST_DIR="${REPO}/hosts/${HOST}"
DEPLOY_HOST=""
DEPLOY_KEY=""
DEPLOY_HOST_KEY_ALIAS=""
DEPLOY_SOCKS=""
DEPLOY_DIR="/data/agentbox"
AGENTBOX_VERSION=""
declare -a SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new)

# hosts/<host>/host.env: connection fields stay local, AGENTBOX_VERSION is derived to the remote.
load_host_env() {
	local f="${HOST_DIR}/host.env" line name val
	[ -d "${HOST_DIR}" ] || die "host ${HOST} not found in ${REPO}/hosts"
	[ -f "${f}" ] || die "missing ${f}"
	while IFS= read -r line || [ -n "${line}" ]; do
		case "${line}" in ''|\#*) continue ;; esac
		name="${line%%=*}"; val="${line#*=}"
		case "${name}" in
			DEPLOY_HOST|DEPLOY_KEY|DEPLOY_HOST_KEY_ALIAS|DEPLOY_SOCKS|DEPLOY_DIR|AGENTBOX_VERSION) ;;
			*) continue ;;
		esac
		# shellcheck disable=SC2088  # matching a literal leading ~/ from the file is the point here
		case "${val}" in "~/"*) val="${HOME}/${val#\~/}" ;; esac
		printf -v "${name}" '%s' "${val}"
	done < "${f}"
	[ -n "${DEPLOY_HOST}" ] || die "${f} does not set DEPLOY_HOST"
	[ -n "${AGENTBOX_VERSION}" ] || die "${f} does not set AGENTBOX_VERSION"
	[ -n "${DEPLOY_KEY}" ] && SSH_OPTS+=(-i "${DEPLOY_KEY}")
	# BSD nc SOCKS5 syntax; ssh substitutes %h %p.
	[ -n "${DEPLOY_SOCKS}" ] && SSH_OPTS+=(-o "ProxyCommand=nc -X 5 -x ${DEPLOY_SOCKS} %h %p")
	[ -n "${DEPLOY_HOST_KEY_ALIAS}" ] && SSH_OPTS+=(-o "HostKeyAlias=${DEPLOY_HOST_KEY_ALIAS}")
	return 0
}

# Instances to act on: the one named on the command line, or every directory under instances/.
list_instances() {
	local d
	if [ -n "${INSTANCE}" ]; then
		[ -d "${HOST_DIR}/instances/${INSTANCE}" ] || die "instance ${INSTANCE} not found under ${HOST_DIR}/instances"
		echo "${INSTANCE}"
		return 0
	fi
	for d in "${HOST_DIR}"/instances/*/; do
		[ -d "${d}" ] || continue
		basename "${d}"
	done
}

# ${VAR} names referenced by string values in the config (real TOML parse: comments do not count).
# The regex must stay identical to the placeholders() function in entrypoint.sh; scripts/test.sh
# asserts the two agree, because a mismatch here means deploy passes and the container then fails.
config_placeholders() {
	python3 - "$1" <<'PY'
import re, sys, tomllib

def walk(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for v in node.values():
            yield from walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v)

try:
    with open(sys.argv[1], "rb") as fh:
        cfg = tomllib.load(fh)
except tomllib.TOMLDecodeError as e:
    print(f"invalid TOML: {e}", file=sys.stderr)
    sys.exit(1)
names = set()
for s in walk(cfg):
    names.update(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", s))
print("\n".join(sorted(names)))
PY
}

# WORK_DIR comes from the compose file, not the env file, so it is not required here.
check_instance() {
	local name="$1" dir toml envf want have missing=()
	dir="${HOST_DIR}/instances/${name}"
	toml="${dir}/config.toml"
	envf="${dir}/env"
	[ -f "${toml}" ] || die "missing ${toml}"
	[ -f "${envf}" ] || die "missing ${envf}"
	want="$(config_placeholders "${toml}")" || die "config ${toml} is not valid TOML (see above)"
	have="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "${envf}" | tr -d '=' | sort -u)"
	local v
	for v in ${want}; do
		[ "${v}" = WORK_DIR ] && continue
		grep -qxF "${v}" <<<"${have}" || missing+=("${v}")
	done
	if [ "${#missing[@]}" -gt 0 ]; then
		echo "错误: instance ${name} references environment variables with no value in ${envf}:" >&2
		printf '  - %s\n' "${missing[@]}" >&2
		return 1
	fi
	vlog "instance ${name}: $(wc -w <<<"${want}") placeholders all resolved"
	return 0
}

check_all_instances() {
	local n rc=0 count=0
	while IFS= read -r n; do
		[ -n "${n}" ] || continue
		count=$((count+1))
		check_instance "${n}" || rc=1
	done < <(list_instances)
	[ "${count}" -gt 0 ] || die "no instances found under ${HOST_DIR}/instances"
	[ "${rc}" -eq 0 ] || die "fix the env files above before deploying"
	return 0
}

# Everything print_plan reports is computed from local files; it must not connect.
print_plan() {
	local n compose="${HOST_DIR}/docker-compose.yaml"
	echo "  repo:      ${REPO}" >&2
	echo "  host:      ${DEPLOY_HOST}  dir ${DEPLOY_DIR}" >&2
	echo "  version:   ${AGENTBOX_VERSION}" >&2
	if [ -f "${compose}" ]; then
		echo "  compose:   ${compose}" >&2
	else
		echo "  compose:   MISSING (${compose})" >&2
	fi
	echo "  will sync: docker-compose.yaml, instances/ (config.toml + env, env as 0600)" >&2
	echo "  will restart these containers, interrupting any session in progress:" >&2
	while IFS= read -r n; do
		[ -n "${n}" ] || continue
		echo "    - ${n}" >&2
	done < <(list_instances)
}

# A deploy from a dirty repo cannot be traced back to a commit. Refuse unless --force says otherwise.
check_repo_clean() {
	if ! git -C "${REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		warn "deploy repo ${REPO} is not a git repository; there is no commit to trace this deploy to"
		return 0
	fi
	local dirty
	dirty="$(git -C "${REPO}" status --porcelain)"
	[ -z "${dirty}" ] && return 0
	if [ "${FORCE}" -eq 1 ]; then
		warn "deploy repo has uncommitted changes; proceeding because --force was given"
		return 0
	fi
	echo "错误: deploy repo ${REPO} has uncommitted changes:" >&2
	sed 's/^/  /' <<<"${dirty}" >&2
	echo "commit them so the deployed state maps to a commit, or pass --force" >&2
	exit 1
}

main() {
	load_host_env
	case "${ACTION}" in
		plan)
			step "planning ${HOST} (${DEPLOY_HOST}) version ${AGENTBOX_VERSION} from ${REPO}"
			check_repo_clean
			check_all_instances
			print_plan
			;;
		deploy)
			step "deploying ${HOST} (${DEPLOY_HOST}) version ${AGENTBOX_VERSION} from ${REPO}"
			check_repo_clean
			check_all_instances
			print_plan
			;;
		status) step "querying ${HOST} (${DEPLOY_HOST}) from ${REPO}" ;;
	esac
}

main
