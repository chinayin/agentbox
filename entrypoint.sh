#!/usr/bin/env bash
# Container entrypoint: check the instance mounts, then exec cc-connect.
# Only what cc-connect cannot report clearly is checked here: config mounted, HOME writable,
# every ${PLACEHOLDER} in the config set. Config schema errors are cc-connect's job.
# Exit codes: 0 from the exec'd process / 1 usage / 2 precondition not met

set -euo pipefail

CONFIG="${AGENTBOX_CONFIG:-/agent/config.toml}"
PROFILE_DIR=/etc/agentbox/profiles
VERSION_FILE=/etc/agentbox/version

die()  { echo "Error: $*" >&2; exit 2; }
warn() { echo "Warning: $*" >&2; }
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
  /agent/skills-lock.json ro optional, skill manifest; named skills are installed into /state
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
		echo "Error: config ${CONFIG} references unset environment variables:" >&2
		printf '  - %s\n' "${missing[@]}" >&2
		echo "provide them via the compose env_file or -e (never put secrets in config.toml)" >&2
		exit 2
	fi
}

# Install the skills the manifests name. The file is whatever `npx skills add` writes -- the
# project lock (skills-lock.json) or the global one (~/.agents/.skill-lock.json); both carry
# skills.<name>.source, which is all that is read here. Nothing about it is agentbox's own format.
#
# The image ships a preset manifest for skills every instance should have; the instance manifest is
# read second and wins on a name. There is no way to unset a preset entry: keep the preset to
# skills that are useful to every instance.
#
# Why not `npx skills experimental_install`, which restores from exactly this file: as of
# skills 2026-09, it writes .agents/skills/<name> without the .claude/skills entry Claude Code
# reads, so a restored skill is invisible. Swap this loop for that command once it materializes the
# agent directory. `skills add` does, which is why it is used here -- one add per skill, because
# several in one command silently stop after the first (docs/SKILLS.md).
install_skills() {
	local preset=/etc/agentbox/skills-lock.json instance name src failed=0 total=0
	instance="$(dirname "${CONFIG}")/skills-lock.json"
	[ -f "${preset}" ] || [ -f "${instance}" ] || return 0
	if ! command -v npx >/dev/null 2>&1; then
		warn "npx not found; no skill from ${preset} or ${instance} was installed"
		return 0
	fi
	while IFS="$(printf '\t')" read -r name src; do
		[ -n "${name}" ] || continue
		total=$((total + 1))
		if [ -d "${HOME}/.claude/skills/${name}" ]; then continue; fi
		info "installing skill ${name} from ${src}"
		if ! npx --yes skills add "${src}" -g -s "${name}" -a claude-code -y >&2; then
			warn "skill ${name} from ${src} failed to install"
		fi
		[ -d "${HOME}/.claude/skills/${name}" ] || failed=$((failed + 1))
	done < <(lock_entries "${preset}" "${instance}" || true)
	report_missing_skills "${failed}" "${total}"
}

# A skill that did not install leaves the agent quietly less capable, and the warning above scrolls
# out of `docker compose logs --tail`. Leave a marker next to the lock npx maintains, so the state
# is readable at any time, not only right after a restart.
report_missing_skills() {
	local failed="$1" total="$2" marker="${HOME}/.agents/.agentbox-skills-missing"
	if [ "${failed}" -eq 0 ]; then
		rm -f "${marker}" 2>/dev/null || true
		return 0
	fi
	warn "${failed} of ${total} skills in the manifest are not installed"
	mkdir -p "${HOME}/.agents" 2>/dev/null || true
	printf '%s\n' "${failed} of ${total} skills failed to install at $(date -u +%Y-%m-%dT%H:%M:%SZ); see the container log" \
		> "${marker}" 2>/dev/null || true
}

# name<TAB>source per skill, later files winning on a name. A manifest that does not parse is a
# warning, not a dead agent.
lock_entries() {
	python3 - "$@" <<'LOCK'
import json, sys
merged = {}
for path in sys.argv[1:]:
    try:
        with open(path, "rb") as fh:
            lock = json.load(fh)
    except FileNotFoundError:
        continue
    except (OSError, ValueError) as e:
        print(f"Warning: skill manifest {path} is unreadable: {e}", file=sys.stderr)
        continue
    for name, meta in (lock.get("skills") or {}).items():
        src = (meta or {}).get("source") or (meta or {}).get("sourceUrl")
        if src:
            merged[name] = src
for name, src in merged.items():
    print(f"{name}\t{src}")
LOCK
}

main() {
	# Deliberate deviation from gox-code-rules:shell, which says to reject unknown options: this is a
	# pass-through wrapper, and every flag it does not claim below belongs to cc-connect. Rejecting
	# them here would make cc-connect's own CLI unreachable from `docker run`.
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

	install_skills

	info "starting cc-connect with config ${CONFIG}"
	exec cc-connect --config "${CONFIG}" "$@"
}

main "$@"
