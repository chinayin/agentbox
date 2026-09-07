#!/usr/bin/env bash
# Scaffold a new agentbox instance (one trust domain = one compose service).
# Copies examples/demo/ as the template, creates the workspace directory and prints the compose
# snippet on stdout. It never edits docker-compose.yaml and never writes secret values.
# Exit codes: 0 ok / 1 usage error or target exists / 2 precondition (template missing)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
NAME=""
AGENT="claudecode"
WORKSPACES_ROOT="./runtime/workspaces"
DRY_RUN=0
declare -a MOUNTS=()

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "scaffold: $*" >&2; }

usage() {
	cat <<'USAGE'
Usage: scaffold.sh [options] <name>

Create examples/<name>/{config.toml,env.example} from the demo template, create the workspace
directory, and print the docker-compose service + volume snippet on stdout.

Arguments:
  <name>                  instance name: lowercase letters, digits, dashes; starts with a letter

Options:
      --agent TYPE        claudecode (default) or pi; pi selects the -pi image in the snippet
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
[ -f "${TEMPLATE}/config.toml" ] && [ -f "${TEMPLATE}/env.example" ] \
	|| { echo "error: template ${TEMPLATE} is incomplete (config.toml + env.example required)" >&2; exit 2; }
[ ! -e "${TARGET}" ] || die "${TARGET} already exists; pick another name or remove it first"

WS_DIR="${WORKSPACES_ROOT}/${NAME}"
case "${WS_DIR}" in /*) WS_ABS="${WS_DIR}" ;; *) WS_ABS="${ROOT}/${WS_DIR#./}" ;; esac

if [ "${DRY_RUN}" -eq 1 ]; then
	echo "plan: create ${TARGET}/config.toml (name=${NAME}, agent.type=${AGENT})" >&2
	echo "plan: create ${TARGET}/env.example" >&2
	echo "plan: create workspace ${WS_ABS}" >&2
	echo "plan: print compose snippet for service '${NAME}'" >&2
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

info "created ${TARGET}/config.toml"
info "created ${TARGET}/env.example"
info "created workspace ${WS_ABS} (owner must match the image's AGENT_UID, default 1000)"
for m in "${MOUNTS[@]+"${MOUNTS[@]}"}"; do
	grep -qxF "examples/*/${m}" "${ROOT}/.gitignore" 2>/dev/null \
		|| info "warning: examples/*/${m} is not in .gitignore; add it before creating the file"
done

# Snippet on stdout: data only, so it can be redirected or pasted.
{
	echo "  # --- add under services: ---"
	echo "  ${NAME}:"
	echo "    <<: *agentbox"
	echo "    container_name: agentbox-${NAME}"
	[ "${AGENT}" = pi ] && echo '    image: ${AGENTBOX_IMAGE_PI:-agentbox:dev-pi}'
	echo "    env_file:"
	echo "      - ./examples/${NAME}/env"
	echo "    volumes:"
	echo "      - ./examples/${NAME}/config.toml:/agent/config.toml:ro"
	echo "      - \${WORKSPACES_ROOT:-${WORKSPACES_ROOT}}/${NAME}:/workspace"
	echo "      - ${NAME}-state:/state"
	echo "      - ${NAME}-cache:/cache"
	for m in "${MOUNTS[@]+"${MOUNTS[@]}"}"; do
		echo "      - ./examples/${NAME}/${m}:/agent/${m}:ro"
	done
	echo
	echo "  # --- add under volumes: ---"
	echo "  ${NAME}-state:"
	echo "  ${NAME}-cache:"
}
