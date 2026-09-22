#!/usr/bin/env bash
# Scaffold a new agentbox instance (one trust domain = one compose project = one directory) straight
# into the deploy repo: hosts/<host>/instances/<name>/{docker-compose.yaml,config.toml,env}, cut from
# examples/demo/. When the repo lacks defaults.env or hosts/<host>/host.env they are laid out from the
# templates in .claude/skills/deploy/references/, placeholders only. It never writes secret values.
# The deploy repo comes from --repo, AGENTBOX_DEPLOY_REPO, or <root>/deploy-repo.
# File credentials are not a scaffold concern: the template already mounts ./home:/agent/home:ro.
# Exit codes: 0 ok / 1 usage error or target exists / 2 precondition (deploy repo or template missing)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
NAME=""
HOST="default"
AGENT="claudecode"
REPO="${AGENTBOX_DEPLOY_REPO:-}"
DRY_RUN=0

die()  { echo "Error: $*" >&2; exit 1; }
pre()  { echo "Error: $*" >&2; exit 2; }
warn() { echo "Warning: $*" >&2; }
info() { echo "scaffold: $*" >&2; }

usage() {
	cat <<'USAGE'
Usage: scaffold.sh [options] <name>

Create hosts/<host>/instances/<name>/{docker-compose.yaml,config.toml,env} in the deploy repo from
the examples/demo template. defaults.env and hosts/<host>/host.env are laid out from templates when
missing, placeholders only. Nothing is printed on stdout; progress and the files that still need
values go to stderr.

Arguments:
  <name>                  instance name: lowercase letters, digits, dashes; starts with a letter

Options:
      --host HOST         host directory under hosts/ (default: default)
      --agent TYPE        claudecode (default) or pi; pi selects the -pi image in docker-compose.yaml
      --repo DIR          deploy repository (default: <agentbox root>/deploy-repo, or AGENTBOX_DEPLOY_REPO)
      --root DIR          agentbox root (default: derived from this script's location)
      --dry-run           print the plan on stderr, change nothing
  -h, --help              show this help

Exit codes: 0 success / 1 usage error or the instance already exists / 2 deploy repo or template missing
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--host)    HOST="${2:?missing value}"; shift 2 ;;
		--agent)   AGENT="${2:?missing value}"; shift 2 ;;
		--repo)    REPO="${2:?missing value}"; shift 2 ;;
		--root)    ROOT="$(cd "${2:?missing value}" && pwd)"; shift 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) usage; exit 0 ;;
		--)        shift; break ;;
		-*)        usage >&2; die "unknown option: $1" ;;
		*)         [ -z "${NAME}" ] || { usage >&2; die "only one name is accepted"; }; NAME="$1"; shift ;;
	esac
done
[ $# -eq 0 ] || { [ -z "${NAME}" ] || { usage >&2; die "only one name is accepted"; }; NAME="$1"; }

[ -n "${NAME}" ] || { usage >&2; die "<name> is required"; }
[[ "${NAME}" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "invalid name '${NAME}': use [a-z][a-z0-9-]{0,31}"
[[ "${HOST}" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "invalid host '${HOST}': use [a-z][a-z0-9-]{0,31}"
[ "${NAME}" != demo ] || die "'demo' is the template itself"
case "${AGENT}" in claudecode|pi) ;; *) die "--agent must be claudecode or pi" ;; esac

if [ -z "${REPO}" ]; then
	[ -d "${ROOT}/deploy-repo" ] || pre "no deploy repo: clone or symlink the private deploy repository to ${ROOT}/deploy-repo, or pass --repo (see .claude/skills/deploy/references/deploy-repo.md)"
	REPO="${ROOT}/deploy-repo"
fi
[ -d "${REPO}" ] || pre "deploy repo ${REPO} is not a directory"

TEMPLATE="${ROOT}/examples/demo"
REFS="${ROOT}/.claude/skills/deploy/references"
[ -f "${TEMPLATE}/config.toml" ] && [ -f "${TEMPLATE}/env.example" ] && [ -f "${TEMPLATE}/docker-compose.yaml" ] \
	|| pre "template ${TEMPLATE} is incomplete (docker-compose.yaml + config.toml + env.example required)"
[ -f "${REFS}/host.env.example" ] && [ -f "${REFS}/defaults.env.example" ] \
	|| pre "templates ${REFS}/host.env.example and defaults.env.example are required"

HOST_DIR="${REPO}/hosts/${HOST}"
TARGET="${HOST_DIR}/instances/${NAME}"
[ ! -e "${TARGET}" ] || die "${TARGET} already exists; pick another name or remove it first"
git -C "${REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || warn "${REPO} is not a git repository; deploy cannot trace a deploy back to a commit"

# Files the user has to fill in before deploy plan passes; listed on stderr at the end.
declare -a TO_FILL=()

if [ "${DRY_RUN}" -eq 1 ]; then
	[ -f "${REPO}/defaults.env" ] || echo "plan: create ${REPO}/defaults.env from template" >&2
	[ -f "${HOST_DIR}/host.env" ] || echo "plan: create ${HOST_DIR}/host.env from template" >&2
	echo "plan: create ${TARGET}/docker-compose.yaml (service ${NAME}, agent ${AGENT})" >&2
	echo "plan: create ${TARGET}/config.toml (name=${NAME}, agent.type=${AGENT})" >&2
	echo "plan: create ${TARGET}/env (0600, placeholders)" >&2
	exit 0
fi

install -d -m 0755 "${TARGET}"

if [ ! -f "${REPO}/defaults.env" ]; then
	cp "${REFS}/defaults.env.example" "${REPO}/defaults.env"
	info "created ${REPO}/defaults.env"
	TO_FILL+=("${REPO}/defaults.env")
fi
if [ ! -f "${HOST_DIR}/host.env" ]; then
	cp "${REFS}/host.env.example" "${HOST_DIR}/host.env"
	info "created ${HOST_DIR}/host.env"
	TO_FILL+=("${HOST_DIR}/host.env")
fi

# config.toml: rename the project and set the agent type.
sed -e "s/^name = \"demo\"$/name = \"${NAME}\"/" \
    -e "s/^type = \"claudecode\"$/type = \"${AGENT}\"/" \
    "${TEMPLATE}/config.toml" > "${TARGET}/config.toml"
grep -q "^name = \"${NAME}\"$" "${TARGET}/config.toml" || die "template changed: project name line not found"
grep -q "^type = \"${AGENT}\"$" "${TARGET}/config.toml" || die "template changed: agent type line not found"

# env: the template's env.example, as the real file the user fills in. pi needs its own key.
if [ "${AGENT}" = pi ]; then
	sed -e 's/^# PI_KEY=$/PI_KEY=xxxxxxxxxxxxxxxxxxxxxxxx/' "${TEMPLATE}/env.example" > "${TARGET}/env"
	grep -q '^PI_KEY=' "${TARGET}/env" || die "template changed: PI_KEY line not found"
else
	cp "${TEMPLATE}/env.example" "${TARGET}/env"
fi
chmod 0600 "${TARGET}/env"
TO_FILL+=("${TARGET}/env")

# docker-compose.yaml: rename the service, container and workspace, switch the image tag for pi.
# The indented "# ..." hints in the template are dropped: a scaffolded file lists what it mounts,
# nothing else; the home layer mount comes through as it is.
sed -e "s/^  demo:\$/  ${NAME}:/" \
    -e "s/^    container_name: agentbox-demo\$/    container_name: agentbox-${NAME}/" \
    -e "s|/demo:/workspace\$|/${NAME}:/workspace|" \
    -e '/^      #/d' \
    "${TEMPLATE}/docker-compose.yaml" > "${TARGET}/docker-compose.yaml"
if [ "${AGENT}" = pi ]; then
	sed -i.bak 's|^\(  image: .*:\${AGENTBOX_VERSION}\)$|\1-pi|' "${TARGET}/docker-compose.yaml" && rm -f "${TARGET}/docker-compose.yaml.bak"
	grep -q 'AGENTBOX_VERSION}-pi$' "${TARGET}/docker-compose.yaml" || die "template changed: image line not found"
fi
grep -q "^  ${NAME}:\$" "${TARGET}/docker-compose.yaml" || die "template changed: service line not found"
grep -q "^    container_name: agentbox-${NAME}\$" "${TARGET}/docker-compose.yaml" || die "template changed: container_name line not found"
grep -q "/${NAME}:/workspace\$" "${TARGET}/docker-compose.yaml" || die "template changed: workspace mount not found"
grep -q '^      - ./home:/agent/home:ro$' "${TARGET}/docker-compose.yaml" || die "template changed: home layer mount not found"

info "created ${TARGET}/docker-compose.yaml"
info "created ${TARGET}/config.toml"
info "created ${TARGET}/env (0600)"
info "fill in real values, then commit the deploy repo and run deploy plan ${HOST} ${NAME}:"
for f in "${TO_FILL[@]}"; do echo "  ${f}" >&2; done
