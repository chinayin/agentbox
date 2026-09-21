#!/usr/bin/env bash
# Verify an instance's cloud profile files against its account registry before deploying.
# For every entry in instances/<name>/home/accounts.yaml it runs the cloud CLI locally with the
# INSTANCE's home layer (home/.aws/config, home/.aliyun/config.json, home/.tccli/, home/.volcengine/,
# never the operator's own ~/.aws or ~/.aliyun) and asserts that
# GetCallerIdentity returns the registered account_id. Moves the "am I on the right account"
# check from the agent's runtime prompt to deploy time (docs/design/CLOUD_ACCOUNTS.md).
# stdout: one line per profile "<cloud> <profile> <expected> <actual> PASS|FAIL|SKIP".
# Exit codes: 0 all pass / 1 usage error or at least one FAIL / 2 precondition (files or CLI missing)

set -euo pipefail

REPO="${AGENTBOX_DEPLOY_REPO:-}"
HOST=""
INSTANCE=""
VERBOSE=0

die()  { echo "Error: $*" >&2; exit 1; }
warn() { echo "Warning: $*" >&2; }
vlog() { [ "${VERBOSE}" -eq 1 ] && echo "verbose: $*" >&2 || true; }

usage() {
	cat <<'USAGE'
Usage: verify-profiles.sh [options] <host> <instance>

Check every profile listed in hosts/<host>/instances/<instance>/home/accounts.yaml: the profile
must exist in that cloud's config file under home/ (laid out like ~), and GetCallerIdentity run with that file
must return the registered account_id. Result lines go to stdout, messages to stderr.

Options:
      --repo PATH    deploy repository (or the AGENTBOX_DEPLOY_REPO environment variable)
  -v, --verbose      show the commands being run (stderr)
  -h, --help         show this help

Exit codes: 0 all profiles pass / 1 usage error or a FAIL / 2 precondition (registry, files or CLI missing)
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)       REPO="${2:?missing value}"; shift 2 ;;
		-v|--verbose) VERBOSE=1; shift ;;
		-h|--help)    usage; exit 0 ;;
		--)           shift; break ;;
		-*)           usage >&2; die "unknown option: $1" ;;
		*)            if [ -z "${HOST}" ]; then HOST="$1"; elif [ -z "${INSTANCE}" ]; then INSTANCE="$1"; else usage >&2; die "too many arguments"; fi; shift ;;
	esac
done
while [ $# -gt 0 ]; do
	if [ -z "${HOST}" ]; then HOST="$1"; elif [ -z "${INSTANCE}" ]; then INSTANCE="$1"; else usage >&2; die "too many arguments"; fi
	shift
done
[ -n "${HOST}" ] && [ -n "${INSTANCE}" ] || { usage >&2; die "<host> and <instance> are required"; }
[ -n "${REPO}" ] || die "deploy repo not set: pass --repo or export AGENTBOX_DEPLOY_REPO"

DIR="${REPO}/hosts/${HOST}/instances/${INSTANCE}/home"
REG="${DIR}/accounts.yaml"
[ -d "${DIR}" ] || { echo "Error: home directory not found: ${DIR}" >&2; exit 2; }
[ -f "${REG}" ] || { echo "Error: registry not found: ${REG}" >&2; exit 2; }
command -v python3 >/dev/null || { echo "Error: python3 is required to read the registry" >&2; exit 2; }

# The registry is a flat YAML list; parse only the three keys this script needs. Commented-out
# entries are ignored, so an account without credentials yet can stay in the file as a note.
entries="$(python3 - "${REG}" <<'PY'
import re, sys
cur = None
out = []
for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.split("#", 1)[0].rstrip()
    if not line.strip():
        continue
    m = re.match(r"^-\s+profile:\s*(\S+)", line)
    if m:
        cur = {"profile": m.group(1), "cloud": "", "account_id": ""}
        out.append(cur)
        continue
    m = re.match(r"^\s+(cloud|account_id):\s*(.+)$", line)
    if m and cur is not None:
        cur[m.group(1)] = m.group(2).strip().strip('"').strip("'")
for e in out:
    if not e["cloud"] or not e["account_id"]:
        print(f"Error: registry entry {e['profile']} lacks cloud or account_id", file=sys.stderr)
        sys.exit(1)
    print(e["cloud"], e["profile"], e["account_id"])
PY
)" || { echo "Error: could not parse ${REG}" >&2; exit 2; }
[ -n "${entries}" ] || { echo "Error: registry has no entries: ${REG}" >&2; exit 2; }

# tccli and ve only read their config from HOME. The instance's home/ is laid out like ~, but the
# CLIs may write next to their config, so point a throwaway HOME's dotdirs at the instance's files
# instead of using home/ itself. The operator's own profiles are never consulted.
FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "${FAKE_HOME}"' EXIT
[ -d "${DIR}/.tccli" ] && ln -s "${DIR}/.tccli" "${FAKE_HOME}/.tccli"
[ -d "${DIR}/.volcengine" ] && ln -s "${DIR}/.volcengine" "${FAKE_HOME}/.volcengine"

# profile_in_file <cloud> <profile>: 0 if the profile exists in that cloud's config file
profile_in_file() {
	case "$1" in
		aws)    grep -qE "^\[profile[[:space:]]+$2\][[:space:]]*$" "${DIR}/.aws/config" 2>/dev/null ;;
		aliyun) python3 -c 'import json,sys; sys.exit(0 if any(p.get("name")==sys.argv[2] for p in json.load(open(sys.argv[1]))["profiles"]) else 1)' "${DIR}/.aliyun/config.json" "$2" 2>/dev/null ;;
		qcloud) [ -f "${DIR}/.tccli/$2.credential" ] ;;
		volc)   python3 -c 'import json,sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1]))["profiles"] else 1)' "${DIR}/.volcengine/config.json" "$2" 2>/dev/null ;;
		*)      return 1 ;;
	esac
}

# caller_account <cloud> <profile>: prints the account id GetCallerIdentity returns, or nothing
caller_account() {
	case "$1" in
		aws)
			vlog "aws sts get-caller-identity --profile $2 (AWS_CONFIG_FILE=${DIR}/.aws/config)"
			AWS_CONFIG_FILE="${DIR}/.aws/config" AWS_SHARED_CREDENTIALS_FILE="${DIR}/.aws/config" AWS_EC2_METADATA_DISABLED=true \
				aws sts get-caller-identity --profile "$2" --query Account --output text 2>/dev/null ;;
		aliyun)
			vlog "aliyun sts GetCallerIdentity --profile $2 --config-path ${DIR}/.aliyun/config.json"
			aliyun sts GetCallerIdentity --profile "$2" --config-path "${DIR}/.aliyun/config.json" 2>/dev/null \
				| python3 -c 'import json,sys; print(json.load(sys.stdin).get("AccountId",""))' 2>/dev/null ;;
		qcloud)
			vlog "tccli sts GetCallerIdentity --profile $2 (HOME=${FAKE_HOME})"
			HOME="${FAKE_HOME}" tccli sts GetCallerIdentity --profile "$2" 2>/dev/null \
				| python3 -c 'import json,sys; print(json.load(sys.stdin).get("AccountId",""))' 2>/dev/null ;;
		volc)
			vlog "ve sts GetCallerIdentity --profile $2 (HOME=${FAKE_HOME})"
			HOME="${FAKE_HOME}" VOLCENGINE_DISABLE_DEFAULT_CREDENTIALS=true \
				ve sts GetCallerIdentity --profile "$2" --query Result.AccountId --output text 2>/dev/null ;;
	esac
}

cli_for() { case "$1" in aws) echo aws ;; aliyun) echo aliyun ;; qcloud) echo tccli ;; volc) echo ve ;; *) echo "" ;; esac; }

fail=0
skip=0
while read -r cloud profile expected; do
	cli="$(cli_for "${cloud}")"
	if [ -z "${cli}" ]; then
		echo "${cloud} ${profile} ${expected} - FAIL"
		warn "${profile}: unknown cloud ${cloud} (expected aws, aliyun, qcloud or volc)"
		fail=$((fail + 1)); continue
	fi
	if ! profile_in_file "${cloud}" "${profile}"; then
		echo "${cloud} ${profile} ${expected} - FAIL"
		warn "${profile}: not present in the ${cloud} profile file under ${DIR}"
		fail=$((fail + 1)); continue
	fi
	if ! command -v "${cli}" >/dev/null; then
		echo "${cloud} ${profile} ${expected} - SKIP"
		warn "${profile}: ${cli} is not installed here, identity not checked"
		skip=$((skip + 1)); continue
	fi
	actual="$(caller_account "${cloud}" "${profile}" || true)"
	if [ -z "${actual}" ]; then
		echo "${cloud} ${profile} ${expected} - FAIL"
		warn "${profile}: GetCallerIdentity failed (bad key, no network, or wrong profile mode)"
		fail=$((fail + 1))
	elif [ "${actual}" = "${expected}" ]; then
		echo "${cloud} ${profile} ${expected} ${actual} PASS"
	else
		echo "${cloud} ${profile} ${expected} ${actual} FAIL"
		warn "${profile}: registry says ${expected} but the key belongs to ${actual}"
		fail=$((fail + 1))
	fi
done <<< "${entries}"

# Profiles present in a file but absent from the registry are not errors (the bot cannot name
# them anyway), but the operator should know they are dead weight.
if [ -f "${DIR}/.aws/config" ]; then
	while read -r p; do
		grep -qE "^- +profile: +${p}( |$)" "${REG}" || warn "aws profile ${p} exists in the file but not in the registry"
	done < <(sed -nE 's/^\[profile[[:space:]]+([^]]+)\][[:space:]]*$/\1/p' "${DIR}/.aws/config")
fi
# Profiles with an empty access_key_id are sentinels, not dead weight: see the `current` check below.
if [ -f "${DIR}/.aliyun/config.json" ]; then
	while read -r p; do
		grep -qE "^- +profile: +${p}( |$)" "${REG}" || warn "aliyun profile ${p} exists in the file but not in the registry"
	done < <(python3 -c 'import json,sys; [print(p.get("name","")) for p in json.load(open(sys.argv[1]))["profiles"] if p.get("access_key_id")]' "${DIR}/.aliyun/config.json")
	# aliyun 3.5.0 loads `current` before parsing --profile and refuses every command when it names
	# no profile (seen on devops-agent 2026-09-21). "No default account" is therefore spelled as
	# current pointing at a profile with empty keys, never as an unknown name.
	cur="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c=d.get("current",""); print("ok" if any(p.get("name")==c for p in d["profiles"]) else c or "<empty>")' "${DIR}/.aliyun/config.json" 2>/dev/null || echo "<unreadable>")"
	if [ "${cur}" != ok ]; then
		warn "aliyun current profile ${cur} does not exist in the file; aliyun 3.5.0 refuses every command, point current at a profile with empty keys"
		fail=$((fail + 1))
	fi
fi

[ "${skip}" -eq 0 ] || warn "${skip} profile(s) skipped because the CLI is missing locally"
[ "${fail}" -eq 0 ] || { echo "Error: ${fail} profile(s) failed verification" >&2; exit 1; }
