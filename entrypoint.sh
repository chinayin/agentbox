#!/usr/bin/env bash
# Container entrypoint: check the instance mounts, then exec cc-connect.
# Only what cc-connect cannot report clearly is checked here: config mounted, HOME writable,
# every ${PLACEHOLDER} in the config set. Config schema errors are cc-connect's job.
# Exit codes: 0 from the exec'd process / 1 usage / 2 precondition not met

set -euo pipefail

CONFIG="${AGENTBOX_CONFIG:-/agent/config.toml}"
PROFILE_DIR=/etc/agentbox/profiles
VERSION_FILE=/etc/agentbox/version

die()  { echo "error: $*" >&2; exit 2; }
warn() { echo "warning: $*" >&2; }
info() { echo "agentbox: $*" >&2; }

usage() {
	cat <<'USAGE'
Usage: entrypoint.sh [cc-connect args...]
       entrypoint.sh <command> [args...]

With no arguments, or a first argument starting with -, run the prechecks and then pass
everything through to cc-connect. Otherwise exec the command directly with no prechecks,
so that docker run --rm -it agentbox bash works for debugging.

Mount contract:
  /agent/config.toml   ro   instance declaration (path overridable via AGENTBOX_CONFIG)
  /workspace           rw   workspace, bind-mounted from the host
  /state               rw   session and identity state; HOME points here
  /cache               rw   build cache, one per trust domain
  /opt/toolkit         ro   optional, shared script library; its bin/ is already on PATH
  /etc/claude-code     ro   optional, Claude Code managed layer: settings / CLAUDE.md / .claude/skills
  /refs/<name>         ro   optional, read-only cross-reference to another workspace
  /knowledge           ro   optional, shared knowledge base

Environment variables:
  AGENTBOX_CONFIG      config file path, default /agent/config.toml
  AGENTBOX_PROFILE     runtime mirror profile (cn); default global means upstream sources
  AGENTBOX_PRECHECK    set to 0 to skip the prechecks (debugging only)

Exit codes: 0 success / 1 usage error / 2 precondition not met
USAGE
}

# Export profile defaults for unset variables only. global has no file and exports nothing.
apply_defaults() {
	local p f line name val
	p="${AGENTBOX_PROFILE:-global}"
	[ "${p}" = global ] && return 0
	f="${PROFILE_DIR}/${p}.env"
	[ -f "${f}" ] || { warn "profile ${p} not found (${f}); no defaults applied"; return 0; }
	info "using profile ${p}"
	while IFS= read -r line; do
		case "${line}" in ''|\#*) continue ;; esac
		name="${line%%=*}"
		val="${line#*=}"
		if [ -z "${!name:-}" ]; then
			export "${name}=${val}"
			info "default applied: ${name}"
		fi
	done < "${f}"
}

# ${VAR} names referenced by string values in the config (real TOML parse: comments do not count).
placeholders() {
	python3 - "${CONFIG}" <<'PY'
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

precheck() {
	local ws="${WORK_DIR:-/workspace}" names v missing=()

	[ -f "${CONFIG}" ] || die "config file ${CONFIG} not found; mount /agent/config.toml"
	[ -d "${HOME}" ] || die "HOME directory ${HOME} does not exist; mount /state"
	[ -w "${HOME}" ] || die "HOME directory ${HOME} is not writable; check that the volume owner matches the container user UID"
	[ -d "${ws}" ] || die "workspace ${ws} does not exist; mount a host directory at /workspace"
	[ -n "$(ls -A "${ws}" 2>/dev/null)" ] || warn "workspace ${ws} is empty; the agent will have no code to work on"

	names="$(placeholders)" || die "config ${CONFIG} is not valid TOML (see above)"
	for v in ${names}; do
		[ -n "${!v:-}" ] || missing+=("${v}")
	done
	if [ "${#missing[@]}" -gt 0 ]; then
		echo "error: config ${CONFIG} references unset environment variables:" >&2
		printf '  - %s\n' "${missing[@]}" >&2
		echo "provide them via the compose env_file or -e (never put secrets in config.toml)" >&2
		exit 2
	fi
}

main() {
	case "${1:-}" in
		-h|--help)  usage; exit 0 ;;
		--version)  echo "agentbox $(cat "${VERSION_FILE}" 2>/dev/null || echo dev)"; exit 0 ;;
	esac

	apply_defaults

	# Command mode (first arg not starting with -): run it, no prechecks. Debug entry.
	if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
		info "command mode, skipping prechecks: $*"
		exec "$@"
	fi

	if [ "${AGENTBOX_PRECHECK:-1}" = 1 ]; then
		precheck
	else
		warn "prechecks skipped (AGENTBOX_PRECHECK=0)"
	fi

	info "starting cc-connect with config ${CONFIG}"
	exec cc-connect --config "${CONFIG}" "$@"
}

main "$@"
