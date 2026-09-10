#!/usr/bin/env bash
# Publish agentbox instances to a remote docker host. Configuration and secrets come from a
# separate private deploy repository, one directory per host; images come from GHCR by version.
# The repo path comes from, in order of precedence: --repo, AGENTBOX_DEPLOY_REPO, the skill's .env
# file (../.env next to this script, gitignored; template in ../.env.example).
# Per-host connection details live in the deploy repo at hosts/<host>/host.env and never in here.
# Exit codes: 0 ok / 1 usage error or remote failure / 2 precondition (unreachable, missing tools)

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

die()  { echo "Error: $*" >&2; exit 1; }
pre()  { echo "Error: $*" >&2; exit 2; }
warn() { echo "Warning: $*" >&2; }
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

for t in ssh rsync python3; do
	command -v "${t}" >/dev/null 2>&1 || pre "${t} is required"
done

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
		echo "Error: instance ${name} references environment variables with no value in ${envf}:" >&2
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
	echo "  instances/ on the server is mirrored: directories no longer in the deploy repo are removed" >&2
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
	echo "Error: deploy repo ${REPO} has uncommitted changes:" >&2
	sed 's/^/  /' <<<"${dirty}" >&2
	echo "commit them so the deployed state maps to a commit, or pass --force" >&2
	exit 1
}

# All remote commands go through here; ssh exit code passes through.
rssh() {
	vlog "ssh ${DEPLOY_HOST}: $*"
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "plan: ssh ${DEPLOY_HOST} -- $*" >&2
		return 0
	fi
	ssh "${SSH_OPTS[@]}" "${DEPLOY_HOST}" "$@"
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

# Whitelist transport, one direction only: the host directory's compose file and instances/. The
# agentbox source tree is never involved, and nothing is ever pulled back from the server.
sync_host() {
	local compose="${HOST_DIR}/docker-compose.yaml"
	[ -f "${compose}" ] || die "missing ${compose}"
	step "syncing ${HOST} config to ${DEPLOY_HOST}:${DEPLOY_DIR}"
	local tmp
	tmp="$(mktemp -d)"
	# shellcheck disable=SC2064  # expand tmp now, on purpose
	trap "rm -rf '${tmp}'" RETURN
	make_rsync_ssh "${tmp}/ssh"
	local -a args=(-a --delete)
	[ "${VERBOSE}" -eq 1 ] && args+=(-v)
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "plan: rsync ${args[*]} ${HOST_DIR}/docker-compose.yaml ${HOST_DIR}/instances ${DEPLOY_HOST}:${DEPLOY_DIR}/" >&2
	else
		# 0700, not 0755: rsync -a preserves the source file mode, so instances/*/env can land
		# briefly world-readable before the chmod 600 below runs. Closing the directory to the
		# owner means that window never exposes secrets to another user on the host, regardless
		# of what mode a file arrives with. dockerd (root) and docker compose (run as the owning
		# ssh user) can both still traverse it; see the Task 8 fix report for the full reasoning.
		rssh "install -d -m 0700 '${DEPLOY_DIR}'"
		rsync "${args[@]}" -e "${tmp}/ssh" \
			"${HOST_DIR}/docker-compose.yaml" "${HOST_DIR}/instances" \
			"${DEPLOY_HOST}:${DEPLOY_DIR}/"
	fi
	# The remote .env is derived from host.env, never synced: connection fields stay local.
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "plan: write ${DEPLOY_DIR}/.env with AGENTBOX_VERSION=${AGENTBOX_VERSION}" >&2
		echo "plan: chmod 600 every file under ${DEPLOY_DIR}/instances/*/ (config.toml and claude/ excepted) and chown -R 1000:1000 each instance directory" >&2
	else
		rssh "printf 'AGENTBOX_VERSION=%s\n' '${AGENTBOX_VERSION}' > '${DEPLOY_DIR}/.env'"
		# Every file credential (env, kubeconfig-*, ssh_key) is 0600; config.toml stays readable
		# because the container reads it through the bind mount, and claude/ is a read-only code
		# tree the agent must be able to list. docs/TOOLS.md section 3 explains the split.
		rssh "find '${DEPLOY_DIR}'/instances -mindepth 2 -type f ! -name config.toml ! -path '*/claude/*' -exec chmod 600 {} +"
		rssh "install -d -o 1000 -g 1000 -m 0755 '${DEPLOY_DIR}/workspaces'"
	fi
}

# Workspaces must exist and be owned by the image's AGENT_UID before compose binds them: docker
# creates a missing bind-mount directory as root, and the agent then cannot write to it.
prepare_workspaces() {
	local n
	while IFS= read -r n; do
		[ -n "${n}" ] || continue
		rssh "install -d -o 1000 -g 1000 -m 0755 '${DEPLOY_DIR}/workspaces/${n}'"
		rssh "chown -R 1000:1000 '${DEPLOY_DIR}/instances/${n}'"
	done < <(list_instances)
}

# Pull the pinned version, start containers, then read the entrypoint precheck out of the logs.
remote_up() {
	local ts log svc=""
	[ -n "${INSTANCE}" ] && svc=" ${INSTANCE}"
	ts="$(date +%Y%m%d-%H%M%S)"
	log="${LOG_DIR}/${ts}-deploy-${HOST}.log"
	# The compose snippet declares networks: agentbox: external: true, so the network must exist
	# before the first `docker compose up` on a fresh host; the inspect/create pair is idempotent.
	local ensure_net="docker network inspect agentbox >/dev/null 2>&1 || docker network create agentbox"
	# --force-recreate is what makes a config change land. config.toml and env reach the container
	# as bind mounts, so compose sees an unchanged service definition and leaves the container
	# running -- and rsync replaces the file rather than rewriting it, so even the running
	# container keeps reading the old inode. Without this, plan promises a restart that never
	# happens and the deploy silently has no effect.
	local cmd="${ensure_net} && cd '${DEPLOY_DIR}' && docker compose pull${svc} && docker compose up -d --force-recreate${svc} && docker compose ps"
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "plan: ensure docker network agentbox exists on the host" >&2
		echo "plan: ssh ${DEPLOY_HOST} -- ${cmd}" >&2
		return 0
	fi
	# 0700, and umask 077 while the log is written: docker compose logs can echo container output
	# into it, and that output is not ours to make world-readable.
	install -d -m 0700 "${LOG_DIR}"
	step "starting containers on ${DEPLOY_HOST} (log: ${log})"
	local old_umask rc=0
	old_umask="$(umask)"
	umask 077
	ssh "${SSH_OPTS[@]}" "${DEPLOY_HOST}" "${cmd}" 2>&1 | tee "${log}" >&2 || rc=$?
	if [ "${rc}" -ne 0 ]; then
		umask "${old_umask}"
		echo "Error: remote compose failed (rc=${rc}); full log at ${log}" >&2
		echo "if the pull was denied, log in on the server once: docker login ghcr.io" >&2
		return 1
	fi
	# The entrypoint lists unset placeholders and exits 2; surface that instead of a bare "started".
	local logs
	logs="$(ssh "${SSH_OPTS[@]}" "${DEPLOY_HOST}" "cd '${DEPLOY_DIR}' && docker compose logs --tail 40${svc}" 2>&1 | tee -a "${log}")"
	umask "${old_umask}"
	if grep -q 'references unset environment variables' <<<"${logs}"; then
		echo "Error: a container failed its precheck; see ${log}" >&2
		return 1
	fi
	echo "${log}"
}

do_deploy() {
	sync_host
	[ "${DRY_RUN}" -eq 1 ] || prepare_workspaces
	remote_up
}

do_status() {
	rssh "cd '${DEPLOY_DIR}' && docker compose ps && docker compose logs --tail 20"
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
			do_deploy
			;;
		status)
			step "querying ${HOST} (${DEPLOY_HOST}) from ${REPO}"
			do_status
			;;
	esac
}

main
