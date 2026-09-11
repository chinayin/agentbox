#!/usr/bin/env bash
# Scaffold a new agentbox instance (one trust domain = one compose project = one directory).
# Copies examples/demo/ as the template: config.toml, env.example and the instance's own
# docker-compose.yaml, and creates the workspace directory. It never writes secret values.
# Exit codes: 0 ok / 1 usage error or target exists / 2 precondition (template missing)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
NAME=""
AGENT="claudecode"
WORKSPACES_ROOT="./runtime/workspaces"
DRY_RUN=0
declare -a MOUNTS=()

die()  { echo "Error: $*" >&2; exit 1; }
warn() { echo "Warning: $*" >&2; }
info() { echo "scaffold: $*" >&2; }

usage() {
	cat <<'USAGE'
Usage: scaffold.sh [options] <name>

Create examples/<name>/{docker-compose.yaml,config.toml,env.example} from the demo template and
create the workspace directory. Nothing is printed on stdout; progress goes to stderr.

Arguments:
  <name>                  instance name: lowercase letters, digits, dashes; starts with a letter

Options:
      --agent TYPE        claudecode (default) or pi; pi selects the -pi image in docker-compose.yaml
      --mount FILE        file credential to mount as /agent/FILE:ro (repeatable), e.g. kubeconfig
      --workspaces-root D host directory holding one workspace per instance (default ./runtime/workspaces)
      --root DIR          repository root (default: derived from this script's location)
      --dry-run           print the plan on stderr, change nothing
  -h, --help              show this help

Exit codes: 0 success / 1 usage error or examples/<name> already exists / 2 template missing
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--agent)           AGENT="${2:?missing value}"; shift 2 ;;
		--mount)           MOUNTS+=("${2:?missing value}"); shift 2 ;;
		--workspaces-root) WORKSPACES_ROOT="${2:?missing value}"; shift 2 ;;
		--root)            ROOT="$(cd "${2:?missing value}" && pwd)"; shift 2 ;;
		--dry-run)         DRY_RUN=1; shift ;;
		-h|--help)         usage; exit 0 ;;
		--)                shift; break ;;
		-*)                usage >&2; die "unknown option: $1" ;;
		*)                 [ -z "${NAME}" ] || { usage >&2; die "only one name is accepted"; }; NAME="$1"; shift ;;
	esac
done
[ $# -eq 0 ] || { [ -z "${NAME}" ] || { usage >&2; die "only one name is accepted"; }; NAME="$1"; }

[ -n "${NAME}" ] || { usage >&2; die "<name> is required"; }
[[ "${NAME}" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "invalid name '${NAME}': use [a-z][a-z0-9-]{0,31}"
[ "${NAME}" != demo ] || die "'demo' is the template itself"
case "${AGENT}" in claudecode|pi) ;; *) die "--agent must be claudecode or pi" ;; esac
for m in "${MOUNTS[@]+"${MOUNTS[@]}"}"; do
	[[ "${m}" =~ ^[A-Za-z0-9._-]+$ ]] || die "--mount takes a bare file name, got '${m}'"
	[ "${m}" != config.toml ] || die "config.toml is always mounted; do not pass it to --mount"
done

TEMPLATE="${ROOT}/examples/demo"
TARGET="${ROOT}/examples/${NAME}"
[ -f "${TEMPLATE}/config.toml" ] && [ -f "${TEMPLATE}/env.example" ] && [ -f "${TEMPLATE}/docker-compose.yaml" ] \
	|| { echo "Error: template ${TEMPLATE} is incomplete (docker-compose.yaml + config.toml + env.example required)" >&2; exit 2; }
[ ! -e "${TARGET}" ] || die "${TARGET} already exists; pick another name or remove it first"

WS_DIR="${WORKSPACES_ROOT}/${NAME}"
case "${WS_DIR}" in /*) WS_ABS="${WS_DIR}" ;; *) WS_ABS="${ROOT}/${WS_DIR#./}" ;; esac

if [ "${DRY_RUN}" -eq 1 ]; then
	echo "plan: create ${TARGET}/config.toml (name=${NAME}, agent.type=${AGENT})" >&2
	echo "plan: create ${TARGET}/env.example" >&2
	echo "plan: create ${TARGET}/docker-compose.yaml (service ${NAME}, agent ${AGENT})" >&2
	echo "plan: create workspace ${WS_ABS}" >&2
	exit 0
fi

install -d -m 0755 "${TARGET}" "${WS_ABS}"

# config.toml: rename the project, set the agent type, wire known file credentials into the env block.
sed -e "s/^name = \"demo\"$/name = \"${NAME}\"/" \
    -e "s/^type = \"claudecode\"$/type = \"${AGENT}\"/" \
    "${TEMPLATE}/config.toml" > "${TARGET}/config.toml"
for m in "${MOUNTS[@]+"${MOUNTS[@]}"}"; do
	case "${m}" in
		kubeconfig)
			sed -i.bak "/^ANTHROPIC_AUTH_TOKEN = /a\\
KUBECONFIG = \"/agent/kubeconfig\"" "${TARGET}/config.toml" && rm -f "${TARGET}/config.toml.bak" ;;
		*) info "mount ${m}: no known env variable; wire it by hand per docs/TOOLS.md §2" ;;
	esac
done
grep -q "^name = \"${NAME}\"$" "${TARGET}/config.toml" || die "template changed: project name line not found"
grep -q "^type = \"${AGENT}\"$" "${TARGET}/config.toml" || die "template changed: agent type line not found"

# env.example: pi needs its own key; everything stays a placeholder.
if [ "${AGENT}" = pi ]; then
	sed -e 's/^# PI_KEY=$/PI_KEY=xxxxxxxxxxxxxxxxxxxxxxxx/' "${TEMPLATE}/env.example" > "${TARGET}/env.example"
	grep -q '^PI_KEY=' "${TARGET}/env.example" || die "template changed: PI_KEY line not found"
else
	cp "${TEMPLATE}/env.example" "${TARGET}/env.example"
fi

# docker-compose.yaml: rename the service, container and workspace, switch the image tag for pi,
# add one read-only mount per --mount after the cache volume. The indented "# - ..." hints in the
# template are dropped: a scaffolded file lists what it mounts, nothing else.
sed -e "s/^  demo:\$/  ${NAME}:/" \
    -e "s/^    container_name: agentbox-demo\$/    container_name: agentbox-${NAME}/" \
    -e "s|/demo:/workspace\$|/${NAME}:/workspace|" \
    -e '/^      #/d' \
    "${TEMPLATE}/docker-compose.yaml" > "${TARGET}/docker-compose.yaml"
if [ "${AGENT}" = pi ]; then
	sed -i.bak 's|^\(  image: .*:\${AGENTBOX_VERSION}\)$|\1-pi|' "${TARGET}/docker-compose.yaml" && rm -f "${TARGET}/docker-compose.yaml.bak"
	grep -q 'AGENTBOX_VERSION}-pi$' "${TARGET}/docker-compose.yaml" || die "template changed: image line not found"
fi
# Each insert lands right after the cache line, so walk the list backwards to keep the given order.
for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
	m="${MOUNTS[i]}"
	sed -i.bak "/^      - cache:\/cache\$/a\\
      - ./${m}:/agent/${m}:ro" "${TARGET}/docker-compose.yaml" && rm -f "${TARGET}/docker-compose.yaml.bak"
done
grep -q "^  ${NAME}:\$" "${TARGET}/docker-compose.yaml" || die "template changed: service line not found"
grep -q "^    container_name: agentbox-${NAME}\$" "${TARGET}/docker-compose.yaml" || die "template changed: container_name line not found"
grep -q "/${NAME}:/workspace\$" "${TARGET}/docker-compose.yaml" || die "template changed: workspace mount not found"

info "created ${TARGET}/docker-compose.yaml"
info "created ${TARGET}/config.toml"
info "created ${TARGET}/env.example"
info "created workspace ${WS_ABS} (owner must match the image's AGENT_UID, default 1000)"
for m in "${MOUNTS[@]+"${MOUNTS[@]}"}"; do
	grep -qxF "examples/*/${m}" "${ROOT}/.gitignore" 2>/dev/null \
		|| warn "examples/*/${m} is not in .gitignore; add it before creating the file"
done
