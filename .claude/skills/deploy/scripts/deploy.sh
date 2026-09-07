#!/usr/bin/env bash
# Publish agentbox instances to a remote docker host. Configuration and secrets come from a
# separate private deploy repository, one directory per host; images come from GHCR by version.
# The repo path comes from, in order of precedence: --repo, AGENTBOX_DEPLOY_REPO, the skill's .env
# file (../.env next to this script, gitignored; template in ../.env.example).
# Per-host connection details live in the deploy repo at hosts/<host>/host.env and never in here.
# Exit codes: 0 ok / 1 usage error or remote failure / 2 precondition (unreachable, missing tools)

# shellcheck disable=SC2034  # LOG_DIR/FORCE/DRY_RUN are consumed once later tasks add the
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

main() {
	case "${ACTION}" in
		plan)   step "planning ${HOST} from ${REPO}" ;;
		deploy) step "deploying ${HOST} from ${REPO}" ;;
		status) step "querying ${HOST} from ${REPO}" ;;
	esac
}

main
