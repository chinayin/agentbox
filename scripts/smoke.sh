#!/usr/bin/env bash
# Runtime smoke test against built images. Does not build or touch the repo; temp data under mktemp.
# Exit codes: 0 all pass / 1 usage or check failure / 2 docker unavailable

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE=""
PI_IMAGE=""
PLATFORM=""
JSON=0
PASS=0
FAIL=0
RUN_OUT=""
RUN_RC=0
declare -a RESULTS=()
declare -a PLATFORM_ARGS=()

usage() {
	cat <<'USAGE'
Usage: smoke.sh --image TAG [options]

Run the runtime smoke tests against an already-built agentbox image.

Options:
      --image TAG       agentbox image to test (required)
      --pi-image TAG    optional; also check the pi image variant
      --platform VALUE  optional; passed through to docker run (e.g. linux/amd64)
      --json            machine-readable output (pure JSON on stdout)
  -h, --help            show this help

Exit codes: 0 all checks pass / 1 usage error or check failure / 2 docker precondition not met
USAGE
}

die_usage() {
	usage >&2
	echo "error: $*" >&2
	exit 1
}

die_precondition() {
	echo "error: $*" >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
		--image)
			[ $# -ge 2 ] || die_usage "--image is missing a value"
			IMAGE="$2"; shift 2
			;;
		--pi-image)
			[ $# -ge 2 ] || die_usage "--pi-image is missing a value"
			PI_IMAGE="$2"; shift 2
			;;
		--platform)
			[ $# -ge 2 ] || die_usage "--platform is missing a value"
			PLATFORM="$2"; shift 2
			;;
		--json) JSON=1; shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; [ $# -eq 0 ] || die_usage "positional arguments are not accepted: $*" ;;
		-*) die_usage "unknown option: $1" ;;
		*) die_usage "positional arguments are not accepted: $1" ;;
	esac
done

[ -n "${IMAGE}" ] || die_usage "--image TAG is required"
command -v docker >/dev/null 2>&1 || die_precondition "docker not found"
docker info >/dev/null 2>&1 || die_precondition "cannot reach the docker daemon"

if [ -n "${PLATFORM}" ]; then
	PLATFORM_ARGS=(--platform "${PLATFORM}")
fi

json_str() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//$'\n'/\\n}"
	s="${s//$'\t'/\\t}"
	printf '%s' "${s}"
}

rec() {
	RESULTS+=("{\"check\":\"$(json_str "$1")\",\"status\":\"$2\",\"detail\":\"$(json_str "$3")\"}")
}

ok() {
	PASS=$((PASS+1))
	[ "${JSON}" = 1 ] || echo "  [PASS] $1" >&2
	rec "$1" pass "${2:-}"
}

bad() {
	FAIL=$((FAIL+1))
	[ "${JSON}" = 1 ] || echo "  [FAIL] $1 -- $2" >&2
	rec "$1" fail "$2"
}

group() {
	[ "${JSON}" = 1 ] || { echo >&2; echo "== $1" >&2; }
}

# run_container <image> [docker run opts...] -- [container cmd...]
run_container() {
	local image="$1"
	shift
	local -a opts=()
	while [ $# -gt 0 ] && [ "$1" != "--" ]; do
		opts+=("$1")
		shift
	done
	[ "${1:-}" = "--" ] && shift
	docker run --rm "${PLATFORM_ARGS[@]}" "${opts[@]}" "${image}" "$@"
}

# Capture stderr and stdout separately (interleaving is not ordered), then join stderr first so
# last_line always sees the command's own last stdout line.
run_capture() {
	local out err
	out="$(mktemp)"; err="$(mktemp)"
	if run_container "$@" >"${out}" 2>"${err}"; then
		RUN_RC=0
	else
		RUN_RC=$?
	fi
	RUN_OUT="$(cat "${err}" "${out}")"
	rm -f "${out}" "${err}"
}

last_line() {
	printf '%s\n' "${1##*$'\n'}"
}

# Remove a temp dir the containers wrote into. Their files belong to uid 1000 while the host user
# may be someone else (GitHub's runner is 1001), so a plain rm -rf fails on the entries. Empty it
# from inside the image as root, then drop the host-owned top directory.
scrub_dir() {
	local dir="$1"
	[ -d "${dir}" ] || return 0
	run_container "${IMAGE}" --user 0 --entrypoint find -v "${dir}:/scrub" -- /scrub -mindepth 1 -delete
	rmdir "${dir}"
}

group "claude image"

run_capture "${IMAGE}" -- --version
case "${RUN_OUT}" in
	agentbox*) ok "version entrypoint runs" "${RUN_OUT}" ;;
	*) bad "version entrypoint runs" "rc=${RUN_RC} output=${RUN_OUT}" ;;
esac

run_capture "${IMAGE}" -- sh -c 'printf "%s:%s:%s\n" "$(id -u)" "$(id -un)" "$(id -gn)"'
identity="$(last_line "${RUN_OUT}")"
[ "${RUN_RC}" -eq 0 ] && [ "${identity}" = "1000:agent:agent" ] \
	&& ok "default user is 1000:agent:agent" \
	|| bad "default user is 1000:agent:agent" "rc=${RUN_RC} got=${identity}"

run_capture "${IMAGE}" -- sh -c 'printf "%s\n" "$HOME"'
home_value="$(last_line "${RUN_OUT}")"
[ "${RUN_RC}" -eq 0 ] && [ "${home_value}" = /state ] \
	&& ok "HOME points at /state" \
	|| bad "HOME points at /state" "rc=${RUN_RC} got=${home_value}"

run_capture "${IMAGE}" -- sh -c 'printf "%s\n" "$PATH"'
path_value="$(last_line "${RUN_OUT}")"
# Two adjacent PATH entries defeat a single "*:A:*:B:*" glob; test each separately.
if [ "${RUN_RC}" -eq 0 ] \
	&& case ":${path_value}:" in *:/opt/toolkit/bin:*) true ;; *) false ;; esac \
	&& case ":${path_value}:" in *:/usr/local/share/mise/shims:*) true ;; *) false ;; esac; then
	ok "PATH contains toolkit and mise system shims"
else
	bad "PATH contains toolkit and mise system shims" "rc=${RUN_RC} got=${path_value}"
fi

run_capture "${IMAGE}" -- bash -c '
for b in mise cc-connect claude node go python git python3 curl gpg; do
	command -v "$b" >/dev/null || { echo "MISSING $b"; exit 1; }
done'
[ "${RUN_RC}" -eq 0 ] \
	&& ok "all runtime-critical tools are on PATH" \
	|| bad "all runtime-critical tools are on PATH" "${RUN_OUT}"

run_capture "${IMAGE}" -- sh -c '
test "$MISE_NOT_FOUND_AUTO_INSTALL" = false
test "$MISE_NOT_FOUND_SYSTEM_FALLBACK" = false
test "$MISE_OFFLINE" = true
test "$MISE_ENV" = claude
test "$DISABLE_UPDATES" = 1
test -d /usr/local/share/mise/installs
test -d /usr/local/share/mise/shims
mise ls --installed
'
[ "${RUN_RC}" -eq 0 ] \
	&& ok "mise system scope installed, runtime offline, claude self-update disabled" \
	|| bad "mise system scope installed, runtime offline, claude self-update disabled" "${RUN_OUT}"

# Expected versions come from the lock file, never from mise.toml selectors.
lock_version() {
	local lock="$1" tool="$2"
	python3 - "${ROOT}/${lock}" "${tool}" <<'PY'
import sys, tomllib
lock = tomllib.load(open(sys.argv[1], "rb"))
print(lock["tools"][sys.argv[2]][0]["version"])
PY
}

check_version() {
	local label="$1"
	local expected="$2"
	shift 2
	run_capture "${IMAGE}" -- "$@"
	if [ "${RUN_RC}" -eq 0 ] && printf '%s\n' "${RUN_OUT}" | grep -Fq "${expected}"; then
		ok "${label} version is ${expected}" "${RUN_OUT}"
	else
		bad "${label} version is ${expected}" "rc=${RUN_RC} output=${RUN_OUT}"
	fi
}

# Every lock entry must be installed at its locked version. One loop over the lock; no second tool list.
lock_pairs() {
	python3 - "${ROOT}/$1" <<'PY'
import sys, tomllib
for tool, entries in tomllib.load(open(sys.argv[1], "rb"))["tools"].items():
    print(f"{tool}@{entries[0]['version']}")
PY
}
check_lock_installed() {
	local image="$1" lock="$2" pairs
	pairs="$(lock_pairs "${lock}" | paste -sd' ' -)"
	run_capture "${image}" -- bash -c 'for p in '"${pairs}"'; do mise where "$p" >/dev/null 2>&1 || { echo "MISSING $p"; rc=1; }; done; exit "${rc:-0}"'
	[ "${RUN_RC}" -eq 0 ] \
		&& ok "every tool in ${lock} is installed at its locked version" "${pairs}" \
		|| bad "every tool in ${lock} is installed at its locked version" "${RUN_OUT}"
}
check_lock_installed "${IMAGE}" mise.lock
check_lock_installed "${IMAGE}" mise.claude.lock

# Shims actually execute: only the runtime-critical few, the rest is covered by the lock loop.
check_version "Node" "$(lock_version mise.lock node)" node --version
check_version "Go" "$(lock_version mise.lock go)" go version
check_version "Python" "$(lock_version mise.lock python)" python --version
check_version "cc-connect" "$(lock_version mise.lock "github:chenhg5/cc-connect")" cc-connect --version
check_version "Claude Code" "$(lock_version mise.claude.lock "aqua:anthropics/claude-code")" claude --version

run_capture "${IMAGE}" -- sh -c '
gcc --version >/dev/null
g++ --version >/dev/null
make --version >/dev/null
'
[ "${RUN_RC}" -eq 0 ] \
	&& ok "claude image keeps the native build toolchain" \
	|| bad "claude image keeps the native build toolchain" "${RUN_OUT}"

# `command` is a shell builtin; wrap in sh -c.
run_capture "${IMAGE}" -- sh -c 'command -v pi >/dev/null 2>&1 && echo FOUND || echo ABSENT'
[ "${RUN_RC}" -eq 0 ] && [ "$(last_line "${RUN_OUT}")" = ABSENT ] \
	&& ok "claude image does not contain pi" \
	|| bad "claude image does not contain pi" "rc=${RUN_RC} output=${RUN_OUT}"

run_capture "${IMAGE}" -- helm plugin list
[ "${RUN_RC}" -eq 0 ] && printf '%s\n' "${RUN_OUT}" | awk 'NR>1 {print $1}' | grep -qx diff \
	&& ok "helm-diff plugin is registered" \
	|| bad "helm-diff plugin is registered" "rc=${RUN_RC} output=${RUN_OUT}"

run_capture "${IMAGE}" -- sh -c 'printf "%s\n" "$HELM_PLUGINS"'
helm_plugins="$(last_line "${RUN_OUT}")"
case "${helm_plugins}" in
	/opt/*) ok "HELM_PLUGINS lives in the image layer" "${helm_plugins}" ;;
	*) bad "HELM_PLUGINS lives in the image layer" "rc=${RUN_RC} got=${helm_plugins}" ;;
esac

run_capture "${IMAGE}" -- sh -c 'for d in /state /cache /workspace; do stat -c "%u:%g" "$d"; done | paste -sd, -'
owners="$(last_line "${RUN_OUT}")"
[ "${RUN_RC}" -eq 0 ] && [ "${owners}" = "1000:1000,1000:1000,1000:1000" ] \
	&& ok "mount points are all owned by 1000:1000" \
	|| bad "mount points are all owned by 1000:1000" "rc=${RUN_RC} got=${owners}"

run_capture "${IMAGE}" -- bash -c '
for v in npm_config_cache GOMODCACHE GOCACHE XDG_CACHE_HOME PIP_CACHE_DIR HELM_CACHE_HOME; do
	val="${!v:-}"
	case "$val" in /cache/*) ;; *) echo "$v=$val"; exit 1 ;; esac
done'
[ "${RUN_RC}" -eq 0 ] \
	&& ok "all cache environment variables point at /cache" \
	|| bad "all cache environment variables point at /cache" "${RUN_OUT}"

group "workspace isolation"

# A repo's own mise.toml in /workspace must not redirect the shims (offline would fail).
WS_TMP="$(mktemp -d)"
mkdir -p "${WS_TMP}/sub"
printf '[tools]\nnode = "20.0.0"\n' > "${WS_TMP}/mise.toml"
printf '[tools]\ngo = "1.20"\n' > "${WS_TMP}/sub/mise.toml"
chmod -R 0777 "${WS_TMP}"
node_expected="v$(lock_version mise.lock node)"
go_expected="go$(lock_version mise.lock go)"
run_capture "${IMAGE}" -v "${WS_TMP}:/workspace" -- sh -c 'cd /workspace && node --version && cd sub && go version'
if [ "${RUN_RC}" -eq 0 ] && printf '%s\n' "${RUN_OUT}" | grep -Fq "${node_expected}" && printf '%s\n' "${RUN_OUT}" | grep -Fq "${go_expected}"; then
	ok "a workspace mise.toml does not affect image tool resolution"
else
	bad "a workspace mise.toml does not affect image tool resolution" "rc=${RUN_RC} output=${RUN_OUT}"
fi
scrub_dir "${WS_TMP}"

# Nor may a mise config written into /state (HOME).
ST_TMP="$(mktemp -d)"
mkdir -p "${ST_TMP}/.config/mise"
printf '[tools]\nnode = "20.0.0"\n' > "${ST_TMP}/.config/mise/config.toml"
chmod -R 0777 "${ST_TMP}"
run_capture "${IMAGE}" -v "${ST_TMP}:/state" -- sh -c 'node --version'
if [ "${RUN_RC}" -eq 0 ] && printf '%s\n' "${RUN_OUT}" | grep -Fq "${node_expected}"; then
	ok "a mise global config in the state volume does not affect image tool resolution"
else
	bad "a mise global config in the state volume does not affect image tool resolution" "rc=${RUN_RC} output=${RUN_OUT}"
fi
scrub_dir "${ST_TMP}"

group "runtime profile"

# Every key in cn.env must reach the process environment; keys are read from the repo file.
cn_keys="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "${ROOT}/etc/agentbox/profiles/cn.env" | tr -d '=' | paste -sd' ' -)"
run_capture "${IMAGE}" -e AGENTBOX_PROFILE=cn -- bash -c 'for k in '"${cn_keys}"'; do [ -n "${!k:-}" ] || { echo "UNSET $k"; exit 1; }; done; printf "%s\n" "$GOPROXY"'
if [ "${RUN_RC}" -eq 0 ] && printf '%s\n' "${RUN_OUT}" | grep -Fq "goproxy.cn"; then
	ok "cn profile exports every mirror variable" "${cn_keys}"
else
	bad "cn profile exports every mirror variable" "rc=${RUN_RC} output=${RUN_OUT}"
fi

# global exports nothing; Go falls back to its own default proxy.
run_capture "${IMAGE}" -- bash -c '[ -z "${GOPROXY:-}" ] && [ -z "${PIP_INDEX_URL:-}" ] && go env GOPROXY'
global_profile="$(last_line "${RUN_OUT}")"
if [ "${RUN_RC}" -eq 0 ] && case "${global_profile}" in *"proxy.golang.org"*) true ;; *) false ;; esac; then
	ok "global profile exports no mirror variables; tools use upstream defaults"
else
	bad "global profile exports no mirror variables; tools use upstream defaults" "rc=${RUN_RC} got=${global_profile}"
fi

group "instance contract"

TMP="$(mktemp -d)"
trap 'scrub_dir "${TMP}"' EXIT
mkdir -p "${TMP}/state" "${TMP}/workspace"
chmod 0777 "${TMP}/state" "${TMP}/workspace"
printf 'fixture\n' > "${TMP}/workspace/README"
cat > "${TMP}/config.toml" <<'TOML'
[[projects]]
name = "smoke"
[projects.agent]
type = "claudecode"
[projects.agent.options]
work_dir = "${WORK_DIR}"
[[projects.platforms]]
type = "feishu"
[projects.platforms.options]
app_id = "${FEISHU_APP_ID}"
TOML

# A missing placeholder must be listed before start (exit 2), not surface as a cc-connect restart loop.
run_capture "${IMAGE}" \
	-v "${TMP}/config.toml:/agent/config.toml:ro" \
	-v "${TMP}/state:/state" \
	-v "${TMP}/workspace:/workspace" \
	-- --stub
if [ "${RUN_RC}" -eq 2 ] && printf '%s\n' "${RUN_OUT}" | grep -q "FEISHU_APP_ID"; then
	ok "a missing placeholder is listed before start and exits 2"
else
	bad "a missing placeholder is listed before start and exits 2" "rc=${RUN_RC} output=${RUN_OUT}"
fi

run_capture "${IMAGE}" -- --stub
if [ "${RUN_RC}" -eq 2 ] && printf '%s\n' "${RUN_OUT}" | grep -q "not found; mount /agent/config.toml"; then  # entrypoint-text
	ok "starting without a config fails clearly"
else
	bad "starting without a config fails clearly" "rc=${RUN_RC} output=${RUN_OUT}"
fi

group "bridge startup"

# Start cc-connect for real (fake creds, SIGTERM after 12s): it must get past the lock file next to
# the config and load the config. /agent must be agent-owned (cc-connect v1.5.0).
BR_TMP="$(mktemp -d)"
mkdir -p "${BR_TMP}/state" "${BR_TMP}/workspace"
chmod 0777 "${BR_TMP}/state" "${BR_TMP}/workspace"
printf 'fixture\n' > "${BR_TMP}/workspace/README"
cp "${ROOT}/examples/demo/config.toml" "${BR_TMP}/config.toml"
declare -a BR_ENV=(-e FEISHU_APP_ID=cli_smoke -e FEISHU_APP_SECRET=smoke -e ALLOW_FROM=ou_smoke -e ADMIN_FROM=ou_smoke
	-e ANTHROPIC_BASE_URL=http://127.0.0.1:9 -e ANTHROPIC_AUTH_TOKEN=sk-smoke)
run_capture "${IMAGE}" "${BR_ENV[@]}" \
	-v "${BR_TMP}/config.toml:/agent/config.toml:ro" \
	-v "${BR_TMP}/state:/state" \
	-v "${BR_TMP}/workspace:/workspace" \
	-- sh -c 'timeout -s TERM 12 /entrypoint.sh; true'
# The three strings below are cc-connect's own log output, not ours: an upstream wording change
# breaks this check, and no static assertion in test.sh can catch that.
if printf '%s\n' "${RUN_OUT}" | grep -Fq "acquired instance lock" \
	&& printf '%s\n' "${RUN_OUT}" | grep -Fq "config loaded" \
	&& ! printf '%s\n' "${RUN_OUT}" | grep -Fq "cannot open lock file"; then
	ok "cc-connect starts with a read-only config and loads it"
else
	bad "cc-connect starts with a read-only config and loads it" "output=$(printf '%s\n' "${RUN_OUT}" | tail -5)"
fi
[ -S "${BR_TMP}/state/.cc-connect/run/api.sock" ] || [ -d "${BR_TMP}/state/.cc-connect" ] \
	&& ok "cc-connect state lands in /state/.cc-connect" \
	|| bad "cc-connect state lands in /state/.cc-connect" "$(ls -A "${BR_TMP}/state" | tr '\n' ' ')"
if [ -n "${PI_IMAGE}" ]; then
	sed -i.bak 's/type = "claudecode"/type = "pi"/' "${BR_TMP}/config.toml" && rm -f "${BR_TMP}/config.toml.bak"
	scrub_dir "${BR_TMP}/state" && mkdir "${BR_TMP}/state" && chmod 0777 "${BR_TMP}/state"
	run_capture "${PI_IMAGE}" "${BR_ENV[@]}" \
		-v "${BR_TMP}/config.toml:/agent/config.toml:ro" \
		-v "${BR_TMP}/state:/state" \
		-v "${BR_TMP}/workspace:/workspace" \
		-- sh -c 'timeout -s TERM 12 /entrypoint.sh; true'
	if printf '%s\n' "${RUN_OUT}" | grep -Fq "config loaded" \
		&& ! printf '%s\n' "${RUN_OUT}" | grep -iqE "unsupported agent|unknown agent"; then
		ok "cc-connect accepts agent.type = pi"
	else
		bad "cc-connect accepts agent.type = pi" "output=$(printf '%s\n' "${RUN_OUT}" | tail -5)"
	fi
fi
scrub_dir "${BR_TMP}"

group "image metadata"

if title="$(docker inspect "${IMAGE}" --format '{{index .Config.Labels "org.opencontainers.image.title"}}' 2>&1)" \
	&& [ "${title}" = agentbox ]; then
	ok "OCI title is agentbox"
else
	bad "OCI title is agentbox" "got=${title:-}"
fi

if user="$(docker inspect "${IMAGE}" --format '{{.Config.User}}' 2>&1)" \
	&& [ "${user}" = agent ]; then
	ok "image default USER is agent"
else
	bad "image default USER is agent" "got=${user:-}"
fi

if [ -n "${PI_IMAGE}" ]; then
	group "pi image"
	run_capture "${PI_IMAGE}" -- sh -c 'command -v pi'
	[ "${RUN_RC}" -eq 0 ] && [ -n "$(last_line "${RUN_OUT}")" ] \
		&& ok "pi image contains pi" \
		|| bad "pi image contains pi" "rc=${RUN_RC} output=${RUN_OUT}"
	# Siblings, not layers: the pi image carries neither Claude Code nor its settings.
	run_capture "${PI_IMAGE}" -- sh -c 'command -v claude >/dev/null 2>&1 && echo FOUND || echo ABSENT'
	[ "${RUN_RC}" -eq 0 ] && [ "$(last_line "${RUN_OUT}")" = ABSENT ] \
		&& ok "pi image does not contain claude" \
		|| bad "pi image does not contain claude" "rc=${RUN_RC} output=${RUN_OUT}"
	run_capture "${PI_IMAGE}" -- sh -c 'test "$MISE_ENV" = pi && test -z "${DISABLE_UPDATES:-}"'
	[ "${RUN_RC}" -eq 0 ] \
		&& ok "pi image selects the pi overlay and carries no Claude Code settings" \
		|| bad "pi image selects the pi overlay and carries no Claude Code settings" "rc=${RUN_RC} output=${RUN_OUT}"
	check_lock_installed "${PI_IMAGE}" mise.lock
	check_lock_installed "${PI_IMAGE}" mise.pi.lock
	pi_expected="$(lock_version mise.pi.lock "aqua:earendil-works/pi")"
	run_capture "${PI_IMAGE}" -- pi --version
	if [ "${RUN_RC}" -eq 0 ] && printf '%s\n' "${RUN_OUT}" | grep -Fq "${pi_expected}"; then
		ok "pi version is ${pi_expected}" "${RUN_OUT}"
	else
		bad "pi version is ${pi_expected}" "rc=${RUN_RC} output=${RUN_OUT}"
	fi
	run_capture "${PI_IMAGE}" -- id -un
	pi_user="$(last_line "${RUN_OUT}")"
	[ "${RUN_RC}" -eq 0 ] && [ "${pi_user}" = agent ] \
		&& ok "pi image default user is agent" \
		|| bad "pi image default user is agent" "rc=${RUN_RC} got=${pi_user}"
fi

if [ "${JSON}" = 1 ]; then
	printf '{"pass":%d,"fail":%d,"results":[%s]}\n' \
		"${PASS}" "${FAIL}" "$(IFS=,; echo "${RESULTS[*]}")"
else
	echo >&2
	echo "result: PASS=${PASS} FAIL=${FAIL}" >&2
fi

[ "${FAIL}" -eq 0 ]
