#!/usr/bin/env bash
# Read-only inventory of a bare-metal cc-connect instance, as tab-separated records on stdout.
# Runs on the source host (ssh host bash -s -- DIR < collect.sh) or locally. It reads the instance
# config.toml (full text between marker lines), the .env key names, the owner's home for file
# credentials and user-level skills, the workspace skills, and tool versions. It writes nothing and
# prints no value from .env and no content of a credential file.
# Exit codes: 0 ok / 1 usage error / 2 config.toml not found

set -euo pipefail

DIR=""
HOME_DIR=""

usage() {
	cat <<'USAGE'
Usage: collect.sh [--home DIR] INSTANCE-DIR

Print a read-only inventory of the cc-connect instance in INSTANCE-DIR (the directory holding
config.toml and .env). --home overrides the owner's home directory, which is otherwise derived
from the owner of config.toml.

Exit codes: 0 success / 1 usage error / 2 config.toml not found
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--home)    HOME_DIR="${2:?missing value}"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		--)        shift; break ;;
		-*)        usage >&2; echo "Error: unknown option: $1" >&2; exit 1 ;;
		*)         [ -z "${DIR}" ] || { usage >&2; echo "Error: only one directory is accepted" >&2; exit 1; }; DIR="$1"; shift ;;
	esac
done
[ $# -eq 0 ] || DIR="$1"
[ -n "${DIR}" ] || { usage >&2; echo "Error: the instance directory argument is required" >&2; exit 1; }
[ -f "${DIR}/config.toml" ] || { echo "Error: ${DIR}/config.toml not found" >&2; exit 2; }

rec() { local IFS=$'\t'; printf '%s\n' "$*"; }

# Owner and home: GNU stat on the source host, BSD stat when run locally on macOS.
owner="$(stat -c %U "${DIR}/config.toml" 2>/dev/null || stat -f %Su "${DIR}/config.toml")"
if [ -z "${HOME_DIR}" ]; then
	HOME_DIR="$(getent passwd "${owner}" 2>/dev/null | cut -d: -f6 || true)"
	[ -n "${HOME_DIR}" ] || echo "Warning: cannot derive the home directory of ${owner}; pass --home" >&2
fi
rec owner "${owner}"
rec uid "$(id -u "${owner}" 2>/dev/null || echo '?')"
rec home "${HOME_DIR}"

work_dir="$(sed -nE 's/^[[:space:]]*work_dir[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "${DIR}/config.toml" | head -1)"
rec work_dir "${work_dir}"

# systemd user unit: how the source starts it. Keys and paths only.
for u in "${HOME_DIR}"/.config/systemd/user/*.service; do
	[ -f "${u}" ] || continue
	grep -q cc-connect "${u}" || continue
	rec unit_file "${u}"
	sed -nE 's/^(ExecStart|WorkingDirectory|EnvironmentFile)=(.*)$/unit\t\1\t\2/p; s/^Environment="?([A-Za-z_][A-Za-z0-9_]*)=.*/unit\tEnvironment\t\1/p' "${u}"
done

# .env: names only. The file itself travels by rsync in the import step, never through here.
if [ -f "${DIR}/.env" ]; then
	sed -nE 's/^(export )?([A-Za-z_][A-Za-z0-9_]*)=.*/env_key\t\2/p' "${DIR}/.env"
fi

# File credentials: names and sizes, never contents.
fsize() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }
for f in "${HOME_DIR}"/.kube/*; do
	[ -f "${f}" ] || continue
	rec kube_file "$(basename "${f}")" "$(fsize "${f}")"
done
for f in "${HOME_DIR}"/.ssh/*; do
	[ -f "${f}" ] || continue
	b="$(basename "${f}")"
	case "${b}" in
		config|known_hosts|known_hosts.old|authorized_keys|environment|rc) continue ;;
		*.pub) rec ssh_pub "${b}" ;;
		*) rec ssh_key "${b}" ;;
	esac
done

# Skills: user level (managed layer candidates) and workspace level (stay with the workspace).
docker_hits() { grep -lw docker "$1"/* 2>/dev/null | while IFS= read -r h; do basename "${h}"; done | paste -sd, - || true; }
# A user-level skill is copied verbatim into the deploy repo (see the import step), and skills
# routinely carry a gitignored credential file. Flag names only, never read the file.
skill_creds() {
	local d="$1" skill="$2" f b
	while IFS= read -r f; do
		[ -n "${f}" ] || continue
		b="$(basename "${f}")"
		case "${b}" in
			*.pub) continue ;;
			.env|.env.*|*.pem|id_*|credentials*|*.key) rec skill_cred "${skill}" "${b}" ;;
		esac
	done < <(find "${d}" -type f 2>/dev/null)
}
for d in "${HOME_DIR}"/.claude/skills/*/; do
	[ -f "${d}/SKILL.md" ] || continue
	name="$(basename "${d}")"
	hits="$(docker_hits "${d}")"
	rec user_skill "${name}" "${hits:--}"
	skill_creds "${d}" "${name}"
done
[ -f "${HOME_DIR}/.agents/.skill-lock.json" ] && rec skill_lock "${HOME_DIR}/.agents/.skill-lock.json"
if [ -n "${work_dir}" ] && [ -d "${work_dir}" ]; then
	for d in "${work_dir}"/.claude/skills/*/ "${work_dir}"/skills/*/; do
		[ -f "${d}/SKILL.md" ] || continue
		rel="${d#"${work_dir}"/}"; rel="${rel%/}"
		hits="$(docker_hits "${d}")"
		rec ws_skill "${rel}" "${hits:--}"
	done
	remote="$(git -c safe.directory='*' -C "${work_dir}" config --get remote.origin.url 2>/dev/null | sed -E 's#(://)[^/@]*@#\1#' || true)"
	[ -n "${remote}" ] && rec git_remote "${remote}"
fi

# Tools on the owner's likely PATH. Version is the first line of the tool's own report.
PATH="${PATH}:${HOME_DIR}/.local/bin:${HOME_DIR}/go/bin:/usr/local/go/bin:/usr/local/bin"
declare -a tmo=()
command -v timeout >/dev/null 2>&1 && tmo=(timeout 10)
# HOME=/dev/null (a path nothing, not even root, can create a directory under) so a probed
# binary's own first-run side effects (e.g. go's local telemetry init) fail silently instead of
# writing under the source host login user's real home; the source host stays read-only throughout.
declare -a noh=(env HOME=/dev/null XDG_CONFIG_HOME=/dev/null XDG_CACHE_HOME=/dev/null)
for t in node npm go python3 pip3 uv kubectl helm helmfile kustomize aws aliyun gh glab git jq yq rg fd mise claude cc-connect pi codex cloudflared docker; do
	p="$(command -v "${t}" 2>/dev/null)" || continue
	case "${t}" in
		go)      v="$("${tmo[@]+"${tmo[@]}"}" "${noh[@]}" go version 2>&1 | head -1)" ;;
		kubectl) v="$("${tmo[@]+"${tmo[@]}"}" "${noh[@]}" kubectl version --client 2>/dev/null | head -1)" ;;
		helm)    v="$("${tmo[@]+"${tmo[@]}"}" "${noh[@]}" helm version --short 2>&1 | head -1)" ;;
		*)       v="$("${tmo[@]+"${tmo[@]}"}" "${noh[@]}" "${t}" --version 2>&1 | head -1)" ;;
	esac || v="?"
	rec tool "${t}" "${p}" "${v:0:80}"
done

# The config itself: placeholders and S2 literals by contract. Markers let the renderer cut it out.
rec __AGENTBOX_CONFIG_BEGIN__
cat "${DIR}/config.toml"
rec __AGENTBOX_CONFIG_END__
