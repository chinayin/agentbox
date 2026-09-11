#!/usr/bin/env bash
# Publish agentbox instances to a remote docker host. Configuration and secrets come from a
# separate private deploy repository, one directory per host; images come from GHCR by version.
# Every instance is its own compose project: hosts/<host>/instances/<name>/ holds docker-compose.yaml,
# config.toml, env and file credentials, and `docker compose` runs from inside that directory on the
# server, so an instance moves between hosts as one directory and one instance's broken file cannot
# block another's deploy.
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
VERSION_FLAG=""
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
  status   HOST              remote container state and recent logs, per instance
  remove   HOST INSTANCE     stop an instance the deploy repo no longer has and delete its directory
                             on the server; its state and cache volumes are kept

Options:
      --repo PATH    deploy repository (or the AGENTBOX_DEPLOY_REPO environment variable)
      --image-version TAG
                     image tag for this run only; wins over defaults.env and host.env
      --force        proceed even though the deploy repo has uncommitted changes
      --dry-run      only print the commands that would run
  -v, --verbose      extra diagnostics (to stderr)
  -h, --help         show this help

The deploy repo path can live in the skill's .env file (.claude/skills/deploy/.env, gitignored;
copy .env.example). Flags and environment win. Per-host connection details live in the deploy repo
at hosts/<host>/host.env. The image version comes from --image-version, else that host.env, else
AGENTBOX_VERSION in the repo-level defaults.env; the plan prints which one it used.

Deploy logs are written to runtime/deploy/<timestamp>-<action>-<host>.log under the repo root.

Exit codes: 0 success / 1 usage error or remote command failure / 2 precondition not met
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)  REPO="${2:?missing value}"; shift 2 ;;
		--image-version) VERSION_FLAG="${2:?missing value}"; shift 2 ;;
		--force) FORCE=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-v|--verbose) VERBOSE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*) usage >&2; die "unknown option: $1" ;;
		plan|deploy|status|remove)
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
VERSION_SOURCE=""
declare -a SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new)

# hosts/<host>/host.env: connection fields stay local, AGENTBOX_VERSION is derived to the remote.
# The version is the one field a fleet usually moves together, so it also has a repo-level default
# in defaults.env; a host that must stay behind pins its own in host.env. Connection fields are
# per-host by nature and are never read from defaults.env.
load_host_env() {
	local f="${HOST_DIR}/host.env" d="${REPO}/defaults.env" line name val
	[ -d "${HOST_DIR}" ] || die "host ${HOST} not found in ${REPO}/hosts"
	[ -f "${f}" ] || die "missing ${f}"
	if [ -f "${d}" ]; then
		while IFS= read -r line || [ -n "${line}" ]; do
			case "${line}" in ''|\#*) continue ;; esac
			name="${line%%=*}"; val="${line#*=}"
			if [ "${name}" = AGENTBOX_VERSION ]; then
				AGENTBOX_VERSION="${val}"; VERSION_SOURCE="defaults.env"
			fi
		done < "${d}"
	fi
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
		if [ "${name}" = AGENTBOX_VERSION ]; then VERSION_SOURCE="hosts/${HOST}/host.env"; fi
	done < "${f}"
	if [ -n "${VERSION_FLAG}" ]; then
		AGENTBOX_VERSION="${VERSION_FLAG}"; VERSION_SOURCE="--image-version"
	fi
	[ -n "${DEPLOY_HOST}" ] || die "${f} does not set DEPLOY_HOST"
	[ -n "${AGENTBOX_VERSION}" ] || die "no image version: set AGENTBOX_VERSION in ${f} or ${d}, or pass --image-version"
	[ -n "${DEPLOY_KEY}" ] && SSH_OPTS+=(-i "${DEPLOY_KEY}")
	# BSD nc SOCKS5 syntax; ssh substitutes %h %p.
	[ -n "${DEPLOY_SOCKS}" ] && SSH_OPTS+=(-o "ProxyCommand=nc -X 5 -x ${DEPLOY_SOCKS} %h %p")
	[ -n "${DEPLOY_HOST_KEY_ALIAS}" ] && SSH_OPTS+=(-o "HostKeyAlias=${DEPLOY_HOST_KEY_ALIAS}")
	return 0
}

# Every instance directory in the repo for this host: what the server mirrors, whether or not this
# run restarts it.
all_instances() {
	local d
	for d in "${HOST_DIR}"/instances/*/; do
		[ -d "${d}" ] || continue
		basename "${d}"
	done
}

# Instances to act on: the one named on the command line, or every directory under instances/.
list_instances() {
	if [ -n "${INSTANCE}" ]; then
		[ -d "${HOST_DIR}/instances/${INSTANCE}" ] || die "instance ${INSTANCE} not found under ${HOST_DIR}/instances"
		echo "${INSTANCE}"
		return 0
	fi
	all_instances
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

# The shared block of an instance's docker-compose.yaml is policy. The file is generated from
# examples/demo/docker-compose.yaml, so a missing line means a hand edit; refuse rather than start a
# container without its hardening. Text checks keep plan offline and docker-free; the server runs
# `docker compose config -q` on the rendered file before `up`.
check_compose() {
	local name="$1" f="$2" p bad=()
	for p in 'cap_drop: \[ALL\]' 'no-new-privileges:true' 'pids: [0-9]+' 'external: true' '\$\{AGENTBOX_VERSION\}'; do
		grep -qE "${p}" "${f}" || bad+=("missing ${p}")
	done
	for p in privileged 'docker\.sock' network_mode cap_add; do
		grep -qE "^[^#]*${p}" "${f}" && bad+=("forbidden ${p}")
	done
	[ "${#bad[@]}" -eq 0 ] && return 0
	echo "Error: instance ${name}: ${f} departs from the shared compose block (examples/demo/docker-compose.yaml):" >&2
	printf '  - %s\n' "${bad[@]}" >&2
	return 1
}

# WORK_DIR comes from the compose file, not the env file, so it is not required here.
check_instance() {
	local name="$1" dir toml envf compose want have missing=()
	dir="${HOST_DIR}/instances/${name}"
	toml="${dir}/config.toml"
	envf="${dir}/env"
	compose="${dir}/docker-compose.yaml"
	[ -f "${toml}" ] || die "missing ${toml}"
	[ -f "${envf}" ] || die "missing ${envf}"
	[ -f "${compose}" ] || die "missing ${compose} (every instance is its own compose project; generate it with new-instance or import-instance)"
	check_compose "${name}" "${compose}" || return 1
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
	# A host-level compose file is the pre-2026-09-11 shape; its services now live one per instance.
	[ ! -e "${HOST_DIR}/docker-compose.yaml" ] \
		|| die "hosts/${HOST}/docker-compose.yaml is no longer read: move each service into instances/<name>/docker-compose.yaml (see .claude/skills/deploy/references/deploy-repo.md) and delete it"
	while IFS= read -r n; do
		[ -n "${n}" ] || continue
		count=$((count+1))
		check_instance "${n}" || rc=1
	done < <(list_instances)
	[ "${count}" -gt 0 ] || die "no instances found under ${HOST_DIR}/instances"
	[ "${rc}" -eq 0 ] || die "fix the files above before deploying"
	return 0
}

# Everything print_plan reports is computed from local files; it must not connect.
print_plan() {
	local n
	echo "  repo:      ${REPO}" >&2
	echo "  host:      ${DEPLOY_HOST}  dir ${DEPLOY_DIR}" >&2
	echo "  version:   ${AGENTBOX_VERSION} (from ${VERSION_SOURCE})" >&2
	echo "  will sync: instances/ (docker-compose.yaml + config.toml + env + file credentials, env as 0600)" >&2
	echo "  instances/ on the server is mirrored; a directory the repo no longer has must be retired with remove first" >&2
	echo "  will restart these compose projects (one per instance), interrupting any session in progress:" >&2
	while IFS= read -r n; do
		[ -n "${n}" ] || continue
		echo "    - ${n}  (${HOST_DIR}/instances/${n}/docker-compose.yaml)" >&2
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

# All remote commands go through here; ssh exit code passes through. -n: callers loop over a
# process substitution, and without it ssh would swallow the remaining lines as its stdin.
rssh() {
	vlog "ssh ${DEPLOY_HOST}: $*"
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "plan: ssh ${DEPLOY_HOST} -- $*" >&2
		return 0
	fi
	ssh -n "${SSH_OPTS[@]}" "${DEPLOY_HOST}" "$@"
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

# Whitelist transport, one direction only: the host directory's instances/ tree. The agentbox source
# tree is never involved, and nothing is ever pulled back from the server.
sync_host() {
	step "syncing ${HOST} config to ${DEPLOY_HOST}:${DEPLOY_DIR}"
	local tmp n
	tmp="$(mktemp -d)"
	# shellcheck disable=SC2064  # expand tmp now, on purpose
	trap "rm -rf '${tmp}'" RETURN
	make_rsync_ssh "${tmp}/ssh"
	local -a args=(-a --delete)
	[ "${VERBOSE}" -eq 1 ] && args+=(-v)
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "plan: refuse if the server holds an instance directory the repo no longer has (retire it with remove first)" >&2
		echo "plan: rsync ${args[*]} ${HOST_DIR}/instances ${DEPLOY_HOST}:${DEPLOY_DIR}/" >&2
	else
		# --delete would silently take a retired instance's compose file away while its containers
		# keep running, with nothing left on the server to `down` them. Refuse instead.
		local remote extra=""
		remote="$(rssh "ls -1 '${DEPLOY_DIR}/instances' 2>/dev/null || true")"
		for n in ${remote}; do
			[ -d "${HOST_DIR}/instances/${n}" ] || extra="${extra} ${n}"
		done
		[ -z "${extra}" ] || die "on the server but not in the deploy repo:${extra}; run remove ${HOST} <instance> for each before deploying"
		# 0700, not 0755: rsync -a preserves the source file mode, so instances/*/env can land
		# briefly world-readable before the chmod 600 below runs. Closing the directory to the
		# owner means that window never exposes secrets to another user on the host, regardless
		# of what mode a file arrives with. dockerd (root) and docker compose (run as the owning
		# ssh user) can both still traverse it; see the Task 8 fix report for the full reasoning.
		rssh "install -d -m 0700 '${DEPLOY_DIR}'"
		rsync "${args[@]}" -e "${tmp}/ssh" "${HOST_DIR}/instances" "${DEPLOY_HOST}:${DEPLOY_DIR}/"
	fi
	# Each instance is a compose project rooted in its own directory, so each gets its own .env.
	# It is derived from host.env, never synced: connection fields stay local. Every instance
	# directory gets it, not just the ones this run restarts, because --delete just removed them.
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "plan: write ${DEPLOY_DIR}/instances/<name>/.env with AGENTBOX_VERSION=${AGENTBOX_VERSION} for every instance" >&2
		echo "plan: chmod 600 every file under ${DEPLOY_DIR}/instances/*/ (config.toml and claude/ excepted) and chown -R 1000:1000 each instance directory" >&2
	else
		while IFS= read -r n; do
			[ -n "${n}" ] || continue
			rssh "printf 'AGENTBOX_VERSION=%s\n' '${AGENTBOX_VERSION}' > '${DEPLOY_DIR}/instances/${n}/.env'"
		done < <(all_instances)
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

# Per instance: validate the rendered compose file, pull the pinned version, recreate, then read the
# entrypoint precheck out of the logs. Each instance directory is its own compose project (the
# project name is the directory name), so one instance's failure stops the run without touching the
# others already recreated; the log names the instance it stopped at.
remote_up() {
	local ts log n
	ts="$(date +%Y%m%d-%H%M%S)"
	log="${LOG_DIR}/${ts}-deploy-${HOST}.log"
	# The compose file declares networks: agentbox: external: true, so the network must exist
	# before the first `docker compose up` on a fresh host; the inspect/create pair is idempotent.
	local ensure_net="docker network inspect agentbox >/dev/null 2>&1 || docker network create agentbox"
	# --force-recreate is what makes a config change land. config.toml and env reach the container
	# as bind mounts, so compose sees an unchanged service definition and leaves the container
	# running -- and rsync replaces the file rather than rewriting it, so even the running
	# container keeps reading the old inode. Without this, plan promises a restart that never
	# happens and the deploy silently has no effect.
	local cmd="${ensure_net}"
	while IFS= read -r n; do
		[ -n "${n}" ] || continue
		cmd="${cmd} && echo '==> ${n}' && cd '${DEPLOY_DIR}/instances/${n}' && docker compose config -q && docker compose pull && docker compose up -d --force-recreate && docker compose ps"
	done < <(list_instances)
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
	local logs="" one
	while IFS= read -r n; do
		[ -n "${n}" ] || continue
		one="$(ssh -n "${SSH_OPTS[@]}" "${DEPLOY_HOST}" "cd '${DEPLOY_DIR}/instances/${n}' && docker compose logs --tail 40" 2>&1 | tee -a "${log}")"
		logs="${logs}${one}"
	done < <(list_instances)
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
	rssh "for d in '${DEPLOY_DIR}'/instances/*/; do echo \"==> \$(basename \"\$d\")\"; (cd \"\$d\" && docker compose ps && docker compose logs --tail 20); done"
}

# Retire an instance: the repo no longer has its directory (deleted and committed), the server still
# does. Stop its containers through its own compose file, then delete the directory. State and cache
# volumes are left alone on purpose: the state volume carries session history and tool-written
# credentials, and deleting it is a separate, deliberate `docker volume rm` by a human.
do_remove() {
	[ -n "${INSTANCE}" ] || { usage >&2; die "remove needs an instance name"; }
	[ ! -e "${HOST_DIR}/instances/${INSTANCE}" ] \
		|| die "instance ${INSTANCE} is still in the deploy repo; delete hosts/${HOST}/instances/${INSTANCE}, commit, then remove (a deploy would otherwise bring it back)"
	local d="${DEPLOY_DIR}/instances/${INSTANCE}"
	step "retiring ${INSTANCE} on ${DEPLOY_HOST}: compose down, delete ${d}; volumes are kept"
	rssh "if [ ! -f '${d}/docker-compose.yaml' ]; then echo 'Error: ${d}/docker-compose.yaml not found on the server' >&2; exit 1; fi; cd '${d}' && docker compose down && cd / && rm -rf '${d}'"
	echo "kept: docker volumes of compose project ${INSTANCE}; remove them by hand only if the state is truly no longer needed" >&2
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
		remove)
			check_repo_clean
			do_remove
			;;
	esac
}

main
