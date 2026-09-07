#!/usr/bin/env bash
# Self-test: no docker, no network, writes only under mktemp. Covers entrypoint guards, template
# consistency, mise/lock agreement and image-structure invariants (each one a past incident).
# Exit codes: 0 all pass / 1 failures
# ok/bad always return 0, so `test && ok || bad` never falls into bad by accident.
# shellcheck disable=SC2015

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1 -- ${2:-}"; FAIL=$((FAIL+1)); }
group() { echo; echo "== $1"; }

ENTRY="$ROOT/entrypoint.sh"
DF="$ROOT/Dockerfile"
DEMO_TOML="$ROOT/examples/demo/config.toml"
DEMO_ENV="$ROOT/examples/demo/env.example"
DP_SRC="$ROOT/.claude/skills/deploy/scripts/deploy.sh"

# Controlled PATH: cc-connect is a stub; only python3 (>= 3.11 for tomllib) is linked in, never its
# whole directory, which may contain real CLIs and break "not installed" assertions.
python3 -c 'import tomllib' 2>/dev/null || { echo "error: python3 >= 3.11 required (tomllib)" >&2; exit 2; }
mkdir -p "$TMP/bin"
ln -s "$(command -v python3)" "$TMP/bin/python3"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/cc-connect"; chmod +x "$TMP/bin/cc-connect"
BASE_PATH="$TMP/bin:/usr/bin:/bin"

# Minimal working instance
setup_instance() {
	local dir="$1"
	mkdir -p "$dir/state" "$dir/ws"
	echo placeholder > "$dir/ws/README"
	cat > "$dir/config.toml" <<'TOML'
[[projects]]
name = "t"
[projects.agent]
type = "claudecode"
[projects.agent.options]
work_dir = "${WORK_DIR}"
[[projects.platforms]]
type = "feishu"
[projects.platforms.options]
app_id = "${FEISHU_APP_ID}"
TOML
}

# Run the entrypoint in passthrough mode: full prechecks, then exec into the cc-connect stub
run_entry() {
	local dir="$1"; shift
	env -i PATH="$BASE_PATH" HOME="$dir/state" WORK_DIR="$dir/ws" AGENTBOX_CONFIG="$dir/config.toml" \
		"$@" bash "$ENTRY" --stub 2>&1
}

# TOML helpers: placeholder names / agent.type per project
toml_placeholders() {
	python3 - "$1" <<'PY'
import re, sys, tomllib
def walk(n):
    if isinstance(n, str): yield n
    elif isinstance(n, dict):
        for v in n.values(): yield from walk(v)
    elif isinstance(n, list):
        for v in n: yield from walk(v)
names = set()
for s in walk(tomllib.load(open(sys.argv[1], "rb"))):
    names.update(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", s))
print("\n".join(sorted(names)))
PY
}
toml_agent_types() {
	python3 - "$1" <<'PY'
import sys, tomllib
for p in tomllib.load(open(sys.argv[1], "rb")).get("projects", []):
    t = (p.get("agent") or {}).get("type")
    if isinstance(t, str): print(t)
PY
}

# ---------- entrypoint usage ----------
group "entrypoint usage"
out="$(bash "$ENTRY" --help 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "--help exits 0" || bad "--help exits 0" "rc=$rc"
case "$out" in *"Mount contract"*) ok "--help includes the mount contract" ;; *) bad "--help includes the mount contract" "not present" ;; esac
out="$(bash "$ENTRY" --version 2>&1)"
case "$out" in agentbox*) ok "--version prints the version" ;; *) bad "--version prints the version" "got ${out}" ;; esac

# ---------- template consistency ----------
group "config template consistency"
python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$DEMO_TOML" 2>/dev/null \
	&& ok "demo.toml is valid TOML" || bad "demo.toml is valid TOML" "parse failed"

# Every placeholder in the template must be provided by env.example (WORK_DIR comes from the image)
want="$(toml_placeholders "$DEMO_TOML" | grep -vx WORK_DIR)"
have="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$DEMO_ENV" | tr -d '=' | sort -u)"
missing="$(comm -23 <(echo "$want") <(echo "$have"))"
[ -z "$missing" ] && ok "every template placeholder is provided by examples/demo/env.example" \
	|| bad "every template placeholder is provided by examples/demo/env.example" "missing: $(echo "$missing" | tr '\n' ' ')"

# The commented project block must be valid TOML once uncommented and add exactly one more agent.type
# on top of whatever active projects the demo already has (a deployer may legitimately have added some).
base="$(toml_agent_types "$DEMO_TOML" 2>/dev/null | wc -l | tr -d ' ')"
{ cat "$DEMO_TOML"; sed -n '/^# \[\[projects\]\]/,$p' "$DEMO_TOML" | sed 's/^# \{0,1\}//'; } > "$TMP/two.toml"
n="$(toml_agent_types "$TMP/two.toml" 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" = "$((base + 1))" ] && ok "the commented project template is valid once uncommented and adds one agent.type" \
	|| bad "the commented project template is valid once uncommented and adds one agent.type" "active=$base, with template=$n"

# ---------- entrypoint prechecks ----------
group "entrypoint prechecks"
setup_instance "$TMP/i1"

out="$(env -i PATH="$BASE_PATH" HOME="$TMP/i1/state" WORK_DIR="$TMP/i1/ws" \
	AGENTBOX_CONFIG="$TMP/nope.toml" bash "$ENTRY" --stub 2>&1)"; rc=$?
[ $rc -eq 2 ] && ok "missing config exits 2" || bad "missing config exits 2" "rc=$rc"
case "$out" in *"not found; mount /agent/config.toml"*) ok "missing config reports clearly" ;; *) bad "missing config reports clearly" "$out" ;; esac

out="$(run_entry "$TMP/i1" FEISHU_APP_ID=x)"; rc=$?
[ $rc -eq 0 ] && ok "passes when every placeholder is set" || bad "passes when every placeholder is set" "rc=$rc / $out"

out="$(run_entry "$TMP/i1")"; rc=$?
[ $rc -eq 2 ] && ok "missing placeholder exits 2" || bad "missing placeholder exits 2" "rc=$rc"
case "$out" in *FEISHU_APP_ID*) ok "missing placeholder lists the variable names" ;; *) bad "missing placeholder lists the variable names" "$out" ;; esac
case "$out" in *WORK_DIR*) bad "a placeholder that is set must not be reported missing" "$out" ;; *) ok "a placeholder that is set is not reported missing" ;; esac

# ${...} inside comments is not a placeholder
setup_instance "$TMP/i2"
echo '# foo = "${NOT_REAL}"' >> "$TMP/i2/config.toml"
out="$(run_entry "$TMP/i2" FEISHU_APP_ID=x)"; rc=$?
[ $rc -eq 0 ] && ok "a placeholder inside a comment does not count" || bad "a placeholder inside a comment does not count" "rc=$rc / $out"

# invalid TOML
setup_instance "$TMP/i3"
echo 'broken = "x' >> "$TMP/i3/config.toml"
out="$(run_entry "$TMP/i3" FEISHU_APP_ID=x)"; rc=$?
[ $rc -eq 2 ] && ok "invalid TOML exits 2" || bad "invalid TOML exits 2" "rc=$rc"
case "$out" in *"invalid TOML"*) ok "invalid TOML reports clearly" ;; *) bad "invalid TOML reports clearly" "$out" ;; esac

# state not writable
setup_instance "$TMP/i4"; chmod 500 "$TMP/i4/state"
out="$(run_entry "$TMP/i4" FEISHU_APP_ID=x)"; rc=$?
chmod 700 "$TMP/i4/state"
[ $rc -eq 2 ] && ok "an unwritable state volume exits 2" || bad "an unwritable state volume exits 2" "rc=$rc"
case "$out" in *UID*) ok "the unwritable error mentions a UID mismatch" ;; *) bad "the unwritable error mentions a UID mismatch" "$out" ;; esac

# workspace missing
setup_instance "$TMP/i5"; rm -rf "$TMP/i5/ws"
out="$(run_entry "$TMP/i5" FEISHU_APP_ID=x)"; rc=$?
[ $rc -eq 2 ] && ok "a missing workspace exits 2" || bad "a missing workspace exits 2" "rc=$rc"

# escape hatch
out="$(run_entry "$TMP/i1" AGENTBOX_PRECHECK=0)"; rc=$?
[ $rc -eq 0 ] && ok "PRECHECK=0 skips the prechecks" || bad "PRECHECK=0 skips the prechecks" "rc=$rc"

# command mode: no prechecks, works without a config
out="$(env -i PATH="$BASE_PATH" HOME="$TMP" bash "$ENTRY" true 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "command mode runs no prechecks" || bad "command mode runs no prechecks" "rc=$rc / $out"

# cn profile fills unset variables only; global exports nothing
mkdir -p "$TMP/prof"; printf '# c\nFOO_PROXY=https://cn.example\nBAR=b\n' > "$TMP/prof/cn.env"
out="$(env -i PATH="$BASE_PATH" HOME="$TMP" AGENTBOX_PROFILE=cn BAR=mine \
	bash -c 'sed "s|^PROFILE_DIR=.*|PROFILE_DIR='"$TMP/prof"'|" "'"$ENTRY"'" > "'"$TMP/entry.sh"'"; bash "'"$TMP/entry.sh"'" sh -c "echo \$FOO_PROXY:\$BAR"' 2>/dev/null)"
[ "$out" = "https://cn.example:mine" ] && ok "the cn profile fills only unset variables" || bad "the cn profile fills only unset variables" "got $out"
out="$(env -i PATH="$BASE_PATH" HOME="$TMP" bash "$TMP/entry.sh" sh -c 'echo "${FOO_PROXY:-unset}"' 2>/dev/null)"
[ "$out" = unset ] && ok "global exports no mirror variables" || bad "global exports no mirror variables" "got $out"

# ---------- contract consistency ----------
# The mount contract and the entrypoint's error text each exist in two places. Nothing but these
# checks keeps the copies in step, and smoke.sh only runs with docker, so drift there is silent.
group "contract consistency"

# README table vs the entrypoint's built-in help: the image's --help is what an operator actually reads.
readme_mounts="$(grep '^| `/' "$ROOT/README.md" | sed 's/^| `\([^`]*\)`.*/\1/' | sort)"
entry_mounts="$(sed -n '/^Mount contract:/,/^$/p' "$ENTRY" | grep '^  /' | awk '{print $1}' | sort)"
if [ -z "$readme_mounts" ] || [ -z "$entry_mounts" ]; then
	bad "README and entrypoint --help list the same mounts" "extraction found nothing; the table format changed"
elif [ "$readme_mounts" = "$entry_mounts" ]; then
	ok "README and entrypoint --help list the same mounts"
else
	bad "README and entrypoint --help list the same mounts" "$(diff <(echo "$readme_mounts") <(echo "$entry_mounts") | tr '\n' ' ')"
fi

# smoke.sh greps entrypoint's own wording; those lines are tagged `# entrypoint-text`.
entry_texts="$(sed -n 's/.*grep -q "\([^"]*\)".*# entrypoint-text$/\1/p' "$ROOT/scripts/smoke.sh")"
if [ -z "$entry_texts" ]; then
	bad "smoke.sh entrypoint-text expectations exist in entrypoint.sh" "no tagged line found; the tag was dropped"
else
	stale=""
	while IFS= read -r pattern; do
		grep -Fq "$pattern" "$ENTRY" || stale="${stale}${pattern} | "
	done <<< "$entry_texts"
	[ -z "$stale" ] && ok "smoke.sh entrypoint-text expectations exist in entrypoint.sh" \
		|| bad "smoke.sh entrypoint-text expectations exist in entrypoint.sh" "${stale}"
fi

# Every repo-relative path a doc names in backticks must exist. This is the cheap guard against the
# whole class of "the docs describe a file that was renamed or deleted". ROADMAP.md is excluded on
# purpose: it names files that are planned or already removed. runtime/ paths are not checked:
# that directory is gitignored and absent in a fresh clone, so the docs name it as a destination only.
doc_files=("$ROOT/README.md" "$ROOT/CLAUDE.md")
for f in "$ROOT"/docs/*.md; do
	case "$f" in */ROADMAP.md) continue ;; esac
	doc_files+=("$f")
done
doc_paths="$(grep -ohE '`[^` ]+`' "${doc_files[@]}" 2>/dev/null | tr -d '`' | sort -u | grep -E \
	'^((scripts|docs|examples|etc|\.github|\.claude)/[A-Za-z0-9._/-]*|mise\.(toml|lock|(claude|pi)\.(toml|lock))|Dockerfile|Makefile|docker-compose\.yaml|entrypoint\.sh|\.env\.example|\.dockerignore|\.gitignore|CLAUDE\.md|README\.md|SECURITY\.md|LICENSE)$')"
if [ -z "$doc_paths" ]; then
	bad "every repo path named in the docs exists" "extraction matched nothing; the filter broke"
else
	gone=""
	while IFS= read -r path; do
		[ -e "$ROOT/$path" ] || gone="${gone}${path} "
	done <<< "$doc_paths"
	[ -z "$gone" ] && ok "every repo path named in the docs exists" \
		|| bad "every repo path named in the docs exists" "${gone}"
fi

# deploy.sh gates on placeholders locally, entrypoint.sh gates on them inside the container. If the
# two disagree, a deploy passes and the container then exits 2. Same config in, same names out.
cc="$TMP/cc.toml"
cat > "$cc" <<'TOML'
[[projects]]
name = "c"
[projects.agent.options]
work_dir = "${WORK_DIR}"
[projects.agent.options.env]
UPPER_NAME = "${UPPER_NAME}"
lower_key = "${lower_name}"
mixed = "prefix-${Mixed_9}-suffix"
[[projects.platforms]]
type = "feishu"
[projects.platforms.options]
app_id = "${FEISHU_APP_ID}"
TOML
ep_out="$(CONFIG="$cc" bash -c 'source <(sed -n "/^placeholders()/,/^}/p" "$1"); placeholders' _ "$ENTRY" 2>/dev/null | sort)"
dp_out="$(bash -c 'source <(sed -n "/^config_placeholders()/,/^}/p" "$1"); config_placeholders "$2"' _ "$DP_SRC" "$cc" 2>/dev/null | sort)"
[ -n "$ep_out" ] && [ "$ep_out" = "$dp_out" ] \
	&& ok "deploy.sh and entrypoint.sh extract the same placeholder names" \
	|| bad "deploy.sh and entrypoint.sh extract the same placeholder names" "entrypoint=[$ep_out] deploy=[$dp_out]"

# ---------- mise declaration vs lock ----------
group "mise toolchain declaration"
for f in mise.toml mise.lock mise.claude.toml mise.claude.lock mise.pi.toml mise.pi.lock; do
	[ -f "$ROOT/$f" ] && ok "${f} exists" || bad "${f} exists" "missing"
done

if python3 - "$ROOT" <<'PY'
import pathlib
import sys
import tomllib

root = pathlib.Path(sys.argv[1])
base = tomllib.loads((root / "mise.toml").read_text())
claude = tomllib.loads((root / "mise.claude.toml").read_text())
pi = tomllib.loads((root / "mise.pi.toml").read_text())
assert base["settings"]["lockfile"] is True
assert base["settings"]["registry_floating"] is False
assert base["settings"]["use_versions_host"] is False
assert base["tool_config"]["locked"] is True
# agent CLIs live only in their overlay: the shared toolchain carries no agent
assert "aqua:anthropics/claude-code" not in base["tools"]
assert "aqua:earendil-works/pi" not in base["tools"]
assert list(claude["tools"]) == ["aqua:anthropics/claude-code"]
assert list(pi["tools"]) == ["aqua:earendil-works/pi"]
# mise.toml holds update policy only; kubectl and helm must be prefix-bounded
def selector(value):
    return value if isinstance(value, str) else value["version"]
assert selector(base["tools"]["aqua:kubernetes/kubernetes/kubectl"]).startswith("prefix:1.")
assert selector(base["tools"]["aqua:helm/helm"]).startswith("prefix:")
for config in (base, claude, pi):
    for value in config["tools"].values():
        assert selector(value), "every tool needs a version selector"

def lock_key(name):
    return name.removeprefix("core:")
platforms_wanted = set(base["settings"]["lockfile_platforms"])
for config, lock_name in ((base, "mise.lock"), (claude, "mise.claude.lock"), (pi, "mise.pi.lock")):
    lock = tomllib.loads((root / lock_name).read_text())
    assert lock["lockfile_version"] == 1
    declared = {lock_key(n) for n in config["tools"]}
    assert declared == set(lock["tools"]), (lock_name, declared ^ set(lock["tools"]))
    for tool_name, entries in lock["tools"].items():
        platforms = {}
        for entry in entries:
            assert entry["version"][0].isdigit(), (tool_name, entry["version"])
            platforms.update({
                key.removeprefix("platforms."): value
                for key, value in entry.items()
                if key.startswith("platforms.")
            })
        assert platforms_wanted <= platforms.keys(), tool_name
        for platform in platforms_wanted:
            assert platforms[platform].get("url"), (tool_name, platform)
PY
then
	ok "mise config carries update policy only; lock pins exact versions and matches the toml"
else
	bad "mise config carries update policy only; lock pins exact versions and matches the toml" "TOML does not conform, or the lock and toml tool sets disagree"
fi

# ---------- image structure invariants ----------
group "image structure invariants"

grep -q 'extrepo enable mise' "$DF" && ok "mise is enabled via extrepo" || bad "mise is enabled via extrepo" "missing"
# extrepo is removed only after the final apt install
install_line="$(grep -n 'build-essential mise' "$DF" | head -1 | cut -d: -f1)"
remove_line="$(grep -n 'apt-get remove -y --auto-remove extrepo' "$DF" | head -1 | cut -d: -f1)"
if [ -n "$install_line" ] && [ -n "$remove_line" ] && [ "$install_line" -lt "$remove_line" ]; then
	ok "extrepo is removed after the final dependency install"
else
	bad "extrepo is removed after the final dependency install" "dependency install=${install_line:-missing} extrepo removal=${remove_line:-missing}"
fi
grep -q 'mise install --system' "$DF" && ok "tools are installed in the system scope" || bad "tools are installed in the system scope" "missing"
grep -q 'mise reshim --system' "$DF" && ok "system shims are generated" || bad "system shims are generated" "missing"
grep -q '/usr/local/share/mise/shims' "$DF" && ok "PATH uses the system shims" || bad "PATH uses the system shims" "missing"
grep -q 'MISE_NOT_FOUND_AUTO_INSTALL=false' "$DF" && ok "mise auto-install is disabled at runtime" || bad "mise auto-install is disabled at runtime" "missing"
grep -q 'MISE_NOT_FOUND_SYSTEM_FALLBACK=false' "$DF" && ok "mise shims do not fall back to system tools" || bad "mise shims do not fall back to system tools" "missing"
grep -q 'MISE_OFFLINE=true' "$DF" && ok "mise is forced offline at runtime" || bad "mise is forced offline at runtime" "missing"
# DISABLE_UPDATES is Claude Code's switch; it belongs to the claude stage, not to the shared base or pi
stage_has() { awk -v st="AS $1\$" '$0 ~ "^FROM .* " st {p=1; next} /^FROM /{p=0} p && $0 ~ pat {f=1} END{exit !f}' pat="$2" "$DF"; }
stage_has agentbox-claude 'DISABLE_UPDATES=1' && ok "claude self-update is disabled in the claude stage" || bad "claude self-update is disabled in the claude stage" "missing"
stage_has agentbox 'DISABLE_UPDATES=1' || stage_has agentbox-pi 'DISABLE_UPDATES=1' \
	&& bad "DISABLE_UPDATES stays out of the base and pi stages" "found outside the claude stage" \
	|| ok "DISABLE_UPDATES stays out of the base and pi stages"
grep -qE 'MISE_IGNORED_CONFIG_PATHS=[^ ]*/workspace' "$DF" && ok "mise configs under the workspace are ignored at runtime" || bad "mise configs under the workspace are ignored at runtime" "MISE_IGNORED_CONFIG_PATHS is absent"
grep -qE 'MISE_IGNORED_CONFIG_PATHS=[^ ]*/state' "$DF" && bad "the ignore list excludes /state" "ignoring HOME would drop the system config too" || ok "the ignore list excludes /state"
grep -q 'MISE_GLOBAL_CONFIG_FILE=/etc/mise/config.toml' "$DF" && ok "the global mise config points back at /etc/mise" || bad "the global mise config points back at /etc/mise" "missing"
grep -qE 'MISE_(DATA|CONFIG|CACHE)_DIR=/mise|MISE_INSTALL_PATH=' "$DF" && bad "the single-directory /mise mode is not mixed in" "conflicting variables found" || ok "the single-directory /mise mode is not mixed in"
grep -q 'MISE_LOCKED=' "$DF" && bad "locked mode is declared in mise.toml, not inlined as MISE_LOCKED" "still inlined" || ok "locked mode is declared in mise.toml, not inlined as MISE_LOCKED"
# agent stages run mise with HOME=/state inherited; each must point HOME back to /root while installing
for st in agentbox-claude agentbox-pi; do
	stage_has "$st" 'mise install --system' && stage_has "$st" 'HOME=/root' \
		&& ok "the ${st} stage inlines HOME=/root before installing" \
		|| bad "the ${st} stage inlines HOME=/root before installing" "missing"
done
hp="$(grep -oE 'HELM_PLUGINS=[^ \\]+' "$DF" | head -1 | cut -d= -f2)"
case "${hp:-}" in /opt/*) ok "HELM_PLUGINS lives inside the image (${hp})" ;; *) bad "HELM_PLUGINS lives inside the image" "currently ${hp:-unset}" ;; esac
grep -E '^[^#]*go env -w' "$DF" | grep -q . && bad "GOPROXY is not written with go env -w" "the state volume would override it at runtime" || ok "GOPROXY is not written with go env -w"
grep -E 'install -d -o \$\{AGENT_UID\}' "$DF" | grep -q '/agent' && ok "/agent is owned by the agent user (cc-connect lock file)" || bad "/agent is owned by the agent user (cc-connect lock file)" "missing"
grep -q '^USER ' "$DF" && ok "the Dockerfile declares a non-root USER" || bad "the Dockerfile declares a non-root USER" "missing"
case "$(grep -m1 '^FROM ' "$DF")" in "FROM debian:"*) ok "the base image is debian slim" ;; *) bad "the base image is debian slim" "$(grep -m1 '^FROM ' "$DF")" ;; esac
for st in toolchain agentbox agentbox-claude agentbox-pi; do
	grep -qE "^FROM .* AS ${st}\$" "$DF" && ok "stage ${st} exists" || bad "stage ${st} exists" "missing"
done
grep -E 'useradd|groupadd' "$DF" | grep -q '|| true' && bad "useradd/groupadd do not swallow errors" "found || true" || ok "useradd/groupadd do not swallow errors"

# .dockerignore is an allowlist: only files the Dockerfile COPYs enter the build context
head -1 "$ROOT/.dockerignore" | grep -q '^# ' && sed -n '2p' "$ROOT/.dockerignore" | grep -qx '\*' && ok ".dockerignore is an allowlist (first rule is *)" || bad ".dockerignore is an allowlist (first rule is *)" "see the file"
for f in Dockerfile entrypoint.sh etc/ mise.toml mise.lock mise.claude.toml mise.claude.lock mise.pi.toml mise.pi.lock; do
	grep -qx "!$f" "$ROOT/.dockerignore" && ok ".dockerignore allows $f" || bad ".dockerignore allows $f" "missing"
done

# the image carries exactly one script
grep -q '^ENTRYPOINT \["/entrypoint.sh"\]' "$DF" && ok 'ENTRYPOINT is /entrypoint.sh' || bad 'ENTRYPOINT is /entrypoint.sh' "missing"
grep -E '^COPY .*scripts/' "$DF" | grep -q . && bad "the Dockerfile no longer COPYs anything under scripts/" "see the lines above" || ok "the Dockerfile no longer COPYs anything under scripts/"

# builds always go upstream; no mirror branches, proxies only via docker build args
if grep -nE 'MIRROR_PROFILE|MISE_NODE_MIRROR_URL|MISE_GO_DOWNLOAD_MIRROR|MISE_URL_REPLACEMENTS|mirrors\.aliyun\.com|type=secret' "$DF" | grep -q .; then
	bad "no China-mirror branch at build time" "see the lines above"
else
	ok "no China-mirror branch at build time"
fi

# tool versions only from the lock; a literal tool@x.y in the Dockerfile breaks on the next bump
grep -nE '@[0-9]+\.[0-9]+' "$DF" | grep -v '^[0-9]*:#' | grep -q . && bad "the Dockerfile pins no tool versions" "versions must come from the lock" || ok "the Dockerfile pins no tool versions"
grep -nE 'grep -Fq "(v[0-9]+\.[0-9]+\.[0-9]+|go1\.[0-9]+)' "$ROOT/scripts/smoke.sh" | grep -q . && bad "smoke.sh expected versions come from the lock" "a hardcoded version number was found" || ok "smoke.sh expected versions come from the lock"
# smoke keeps no second tool list; it loops over the lock
grep -c 'check_version "' "$ROOT/scripts/smoke.sh" | awk '{exit !($1 <= 6)}' && ok "smoke.sh version-checks only the runtime-critical shims (the rest loop over the lock)" || bad "smoke.sh version-checks only the runtime-critical shims (the rest loop over the lock)" "too many check_version lines"
# containers write into the smoke temp dirs as uid 1000; a host user with another uid (GitHub's
# runner is 1001) cannot rm -rf those entries, so every cleanup must go through scrub_dir
grep -nE '^[^#]*rm -rf' "$ROOT/scripts/smoke.sh" | grep -q . && bad "smoke.sh removes container-written temp dirs only via scrub_dir" "a plain rm -rf was found" || ok "smoke.sh removes container-written temp dirs only via scrub_dir"

# runtime profile: one cn.env file copied into the image, no global file
CN_ENV="$ROOT/etc/agentbox/profiles/cn.env"
[ -f "$CN_ENV" ] && ok "etc/agentbox/profiles/cn.env exists" || bad "etc/agentbox/profiles/cn.env exists" "missing"
[ ! -e "$ROOT/etc/agentbox/profiles/global.env" ] && ok "no global.env (upstream defaults are not written to a file)" || bad "no global.env (upstream defaults are not written to a file)" "still present"
grep -q '^COPY etc/ /etc/' "$DF" && ok "the Dockerfile COPYs etc/ into the image" || bad "the Dockerfile COPYs etc/ into the image" "missing"
grep -q '> /etc/agentbox/profiles/' "$DF" && bad "the Dockerfile no longer inlines profile content" "a statement writing a profile was found" || ok "the Dockerfile no longer inlines profile content"
if grep -vE '^(#|$|[A-Za-z_][A-Za-z0-9_]*=[^ ]+$)' "$CN_ENV" | grep -q .; then
	bad "every cn.env line is a comment / blank / KEY=value" "$(grep -vE '^(#|$|[A-Za-z_][A-Za-z0-9_]*=[^ ]+$)' "$CN_ENV" | head -3)"
else
	ok "every cn.env line is a comment / blank / KEY=value"
fi

# version: git tag -> build arg -> /etc/agentbox/version
[ ! -e "$ROOT/VERSION" ] && ok "no VERSION file (the version comes from a git tag)" || bad "no VERSION file (the version comes from a git tag)" "still present"
grep -q 'AGENTBOX_VERSION' "$DF" && grep -q '/etc/agentbox/version' "$DF" && ok "the Dockerfile writes the build arg into /etc/agentbox/version" || bad "the Dockerfile writes the build arg into /etc/agentbox/version" "missing"
grep -q '/etc/agentbox/version' "$ENTRY" && ok "entrypoint --version reads the in-image version file" || bad "entrypoint --version reads the in-image version file" "missing"
grep -nE '^VERSION="[0-9]' "$ENTRY" "$ROOT"/scripts/*.sh 2>/dev/null | grep -q . && bad "no hardcoded version constants in the scripts" "see the lines above" || ok "no hardcoded version constants in the scripts"

# cache volume is per trust domain; docs must not describe it as shared across instances.
# The pattern below is Chinese on purpose: it matches the (Chinese) docs, not this script's own
# output. Translating it would make this assertion match nothing and pass forever.
grep -rn '跨实例共享' "$ROOT/README.md" "$ROOT"/docs/*.md "$ROOT/docker-compose.yaml" "$ROOT"/examples "$ENTRY" 2>/dev/null | grep -q . \
	&& bad "cache is no longer described as shared across instances" "see the lines above" || ok "cache is no longer described as shared across instances"

# ---------- template hygiene ----------
# ---------- new-instance skill scaffold ----------
# The skill's scaffold copies examples/demo; these guard the copy against template drift and
# make sure the skill can never produce a non-placeholder value or clobber an existing instance.
group "new-instance scaffold"
SCAFFOLD="$ROOT/.claude/skills/new-instance/scripts/scaffold.sh"
sc="$TMP/scaffold"; mkdir -p "$sc/examples"; cp -R "$ROOT/examples/demo" "$sc/examples/"; cp "$ROOT/.gitignore" "$sc/"
if snippet="$(bash "$SCAFFOLD" --root "$sc" --agent pi --mount kubeconfig data 2>"$sc/err")"; then
	ok "scaffold exits 0 for a fresh name"
else
	bad "scaffold exits 0 for a fresh name" "$(cat "$sc/err")"
fi
python3 -c 'import sys,tomllib; c=tomllib.load(open(sys.argv[1],"rb")); p=c["projects"][0]; assert p["name"]=="data" and p["agent"]["type"]=="pi" and p["agent"]["options"]["env"]["KUBECONFIG"]=="/agent/kubeconfig"' "$sc/examples/data/config.toml" 2>/dev/null \
	&& ok "scaffolded config.toml parses with name, agent type and KUBECONFIG applied" \
	|| bad "scaffolded config.toml parses with name, agent type and KUBECONFIG applied" "see $sc/examples/data/config.toml"
grep -q '^PI_KEY=x' "$sc/examples/data/env.example" \
	&& ok "pi scaffold uncomments PI_KEY with a placeholder" || bad "pi scaffold uncomments PI_KEY with a placeholder" ""
# real TOML parse so commented-out template blocks do not count, same as the entrypoint does
want="$(python3 -c 'import re,sys,tomllib
def walk(n):
    if isinstance(n,str): yield n
    elif isinstance(n,dict):
        for v in n.values(): yield from walk(v)
    elif isinstance(n,list):
        for v in n: yield from walk(v)
names=set()
for v in walk(tomllib.load(open(sys.argv[1],"rb"))): names.update(re.findall(r"\$\{([A-Z_]+)\}",v))
names.discard("WORK_DIR")
print("\n".join(sorted(names)))' "$sc/examples/data/config.toml")"
have="$(grep -oE '^[A-Z_]+=' "$sc/examples/data/env.example" | tr -d = | sort -u)"
[ -z "$(comm -23 <(echo "$want") <(echo "$have"))" ] \
	&& ok "every placeholder in the scaffolded config has a line in env.example" \
	|| bad "every placeholder in the scaffolded config has a line in env.example" "$(comm -23 <(echo "$want") <(echo "$have") | tr '\n' ' ')"
grep -vE '^(#|$)' "$sc/examples/data/env.example" | grep -vE '=(cli_|ou_|sk-)?x+$|=https://[a-z.-]+\.example\.com$' | grep -q . \
	&& bad "scaffolded env.example holds placeholders only" "$(grep -vE '^(#|$)' "$sc/examples/data/env.example" | grep -vE '=(cli_|ou_|sk-)?x+$|example\.com')" \
	|| ok "scaffolded env.example holds placeholders only"
printf '%s\n' "$snippet" | grep -q '^  data:$' && printf '%s\n' "$snippet" | grep -q 'AGENTBOX_IMAGE_PI' \
	&& printf '%s\n' "$snippet" | grep -q 'examples/data/kubeconfig:/agent/kubeconfig:ro' && printf '%s\n' "$snippet" | grep -q '^  data-cache:$' \
	&& ok "snippet names the service, the pi image, the kubeconfig mount and the volumes" \
	|| bad "snippet names the service, the pi image, the kubeconfig mount and the volumes" "$snippet"
[ -d "$sc/runtime/workspaces/data" ] && ok "scaffold creates the workspace directory" || bad "scaffold creates the workspace directory" ""
bash "$SCAFFOLD" --root "$sc" data >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "scaffold refuses to overwrite an existing instance (exit 1)" || bad "scaffold refuses to overwrite an existing instance (exit 1)" "rc=$rc"
bash "$SCAFFOLD" --root "$sc" Bad_Name >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "scaffold rejects an invalid name (exit 1)" || bad "scaffold rejects an invalid name (exit 1)" "rc=$rc"
bash "$SCAFFOLD" --root "$sc" demo >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "scaffold refuses to target the demo template" || bad "scaffold refuses to target the demo template" "rc=$rc"

# ---------- remote-build skill ----------
# The skill's .env supplies defaults; flags and environment must still win, and without any source
# the script must stop with a usage error instead of dialing an empty host.
group "remote-build skill"
RB_SRC="$ROOT/.claude/skills/remote-build/scripts/remote-build.sh"
rb="$TMP/rb"; mkdir -p "$rb/skill/scripts" "$rb/repo"; cp "$RB_SRC" "$rb/skill/scripts/"
printf 'AGENTBOX_REMOTE=user@build.example.test\nAGENTBOX_REMOTE_KEY=~/nope.pem\n' > "$rb/skill/.env"
bash "$rb/skill/scripts/remote-build.sh" --help >/dev/null 2>&1 && ok "remote-build --help exits 0" || bad "remote-build --help exits 0" ""
out="$(env -u AGENTBOX_REMOTE bash "$rb/skill/scripts/remote-build.sh" --dry-run build 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'user@build.example.test' <<<"$out" \
	&& ok "remote-build reads the host from the skill .env" || bad "remote-build reads the host from the skill .env" "rc=$rc $out"
out="$(AGENTBOX_REMOTE=other@env.example.test bash "$rb/skill/scripts/remote-build.sh" --dry-run build 2>&1)"
grep -q 'other@env.example.test' <<<"$out" && ! grep -q 'build.example.test' <<<"$out" \
	&& ok "environment overrides the skill .env" || bad "environment overrides the skill .env" "$out"
out="$(bash "$rb/skill/scripts/remote-build.sh" --remote flag@flag.example.test --dry-run build 2>&1)"
grep -q 'flag@flag.example.test' <<<"$out" && ok "flag overrides the skill .env" || bad "flag overrides the skill .env" "$out"
rm "$rb/skill/.env"
env -u AGENTBOX_REMOTE bash "$rb/skill/scripts/remote-build.sh" --dry-run build >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "remote-build without any host source exits 1" || bad "remote-build without any host source exits 1" "rc=$rc"
# loopback is the documented SOCKS example and is not topology; anything else that looks like an ip is
[ -f "$ROOT/.claude/skills/remote-build/.env.example" ] && ! grep -v '127\.0\.0\.1' "$ROOT/.claude/skills/remote-build/.env.example" | grep -qE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
	&& ok "remote-build .env.example carries no real address" || bad "remote-build .env.example carries no real address" ""
grep -qxF '.claude/skills/*/.env' "$ROOT/.gitignore" && ok "skill .env files are gitignored" || bad "skill .env files are gitignored" ""

# ---------- deploy skill ----------
# Same three-level override as remote-build: the skill .env only fills what is still unset, so the
# environment and flags always win, and with no source at all the script must stop instead of
# operating on an empty path.
group "deploy skill"
dp="$TMP/dp"; mkdir -p "$dp/skill/scripts"; cp "$DP_SRC" "$dp/skill/scripts/"
mkdir -p "$dp/repo/hosts/h1/instances/a1" "$dp/other/hosts/h2/instances/a2"
printf 'DEPLOY_HOST=user@h1.example.test\nDEPLOY_DIR=/data/agentbox\nAGENTBOX_VERSION=0.1.0\n' > "$dp/repo/hosts/h1/host.env"
printf 'DEPLOY_HOST=user@h2.example.test\nDEPLOY_DIR=/data/agentbox\nAGENTBOX_VERSION=0.1.0\n' > "$dp/other/hosts/h2/host.env"
# Every host needs a complete, valid instance once check_all_instances validates locally: config.toml
# plus an env that supplies every placeholder the config references (WORK_DIR excepted; compose
# supplies it, not the env file).
cat > "$dp/repo/hosts/h1/instances/a1/config.toml" <<'TOML'
[[projects]]
name = "a1"
[projects.agent]
type = "claudecode"
[projects.agent.options]
work_dir = "/workspace"
[projects.agent.options.env]
ANTHROPIC_AUTH_TOKEN = "${ANTHROPIC_AUTH_TOKEN}"
[[projects.platforms]]
type = "feishu"
[projects.platforms.options]
app_id = "${FEISHU_APP_ID}"
app_secret = "${FEISHU_APP_SECRET}"
TOML
printf 'ANTHROPIC_AUTH_TOKEN=sk-x\nFEISHU_APP_ID=cli_x\nFEISHU_APP_SECRET=x\n' > "$dp/repo/hosts/h1/instances/a1/env"
cat > "$dp/other/hosts/h2/instances/a2/config.toml" <<'TOML'
[[projects]]
name = "a2"
[projects.agent]
type = "claudecode"
[projects.agent.options]
work_dir = "/workspace"
TOML
: > "$dp/other/hosts/h2/instances/a2/env"
printf 'AGENTBOX_DEPLOY_REPO=%s\n' "$dp/repo" > "$dp/skill/.env"
bash "$dp/skill/scripts/deploy.sh" --help >/dev/null 2>&1 \
	&& ok "deploy --help exits 0" || bad "deploy --help exits 0" ""
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run plan h1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "$dp/repo" <<<"$out" \
	&& ok "deploy reads the repo path from the skill .env" || bad "deploy reads the repo path from the skill .env" "rc=$rc $out"
out="$(AGENTBOX_DEPLOY_REPO="$dp/other" bash "$dp/skill/scripts/deploy.sh" --dry-run plan h2 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "$dp/other" <<<"$out" && ! grep -q "$dp/repo" <<<"$out" \
	&& ok "environment overrides the deploy skill .env" || bad "environment overrides the deploy skill .env" "rc=$rc $out"
out="$(bash "$dp/skill/scripts/deploy.sh" --repo "$dp/other" --dry-run plan h2 2>&1)"
grep -q "$dp/other" <<<"$out" && ok "flag overrides the deploy skill .env" || bad "flag overrides the deploy skill .env" "$out"
rm "$dp/skill/.env"
env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" plan h1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "deploy without any repo source exits 1" || bad "deploy without any repo source exits 1" "rc=$rc"
printf 'AGENTBOX_DEPLOY_REPO=%s\n' "$dp/repo" > "$dp/skill/.env"
[ -f "$ROOT/.claude/skills/deploy/.env.example" ] && ! grep -v '127\.0\.0\.1' "$ROOT/.claude/skills/deploy/.env.example" | grep -qE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
	&& ok "deploy .env.example carries no real address" || bad "deploy .env.example carries no real address" ""
env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run plan nosuchhost >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "deploy rejects an unknown host (exit 1)" || bad "deploy rejects an unknown host (exit 1)" "rc=$rc"
printf 'DEPLOY_DIR=/data/agentbox\n' > "$dp/repo/hosts/h1/host.env"
env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run plan h1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "deploy rejects a host.env without DEPLOY_HOST (exit 1)" || bad "deploy rejects a host.env without DEPLOY_HOST (exit 1)" "rc=$rc"
printf 'DEPLOY_HOST=user@h1.example.test\nDEPLOY_DIR=/data/agentbox\nAGENTBOX_VERSION=0.1.0\n' > "$dp/repo/hosts/h1/host.env"
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run plan h1 2>&1)"
grep -q 'user@h1.example.test' <<<"$out" && grep -q '0.1.0' <<<"$out" \
	&& ok "deploy reads host and version from host.env" || bad "deploy reads host and version from host.env" "$out"
# a1's config.toml (set up above) references ANTHROPIC_AUTH_TOKEN, FEISHU_APP_ID, FEISHU_APP_SECRET;
# drop the last one from env and confirm plan fails locally, naming it, before ever touching a network.
printf 'ANTHROPIC_AUTH_TOKEN=sk-x\nFEISHU_APP_ID=cli_x\n' > "$dp/repo/hosts/h1/instances/a1/env"
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run plan h1 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'FEISHU_APP_SECRET' <<<"$out" \
	&& ok "deploy names the missing placeholder and exits 1" || bad "deploy names the missing placeholder and exits 1" "rc=$rc $out"
printf 'ANTHROPIC_AUTH_TOKEN=sk-x\nFEISHU_APP_ID=cli_x\nFEISHU_APP_SECRET=x\n' > "$dp/repo/hosts/h1/instances/a1/env"
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run plan h1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "deploy plan passes once every placeholder has a value" || bad "deploy plan passes once every placeholder has a value" "rc=$rc $out"
# A dirty deploy repo cannot be traced to a commit; plan/deploy must refuse unless --force says
# otherwise. Make the fixture a real git repo here, so this and every later assertion in this
# group runs against git-tracked state.
( cd "$dp/repo" && git init -q && git add -A && git -c user.email=t@e.test -c user.name=t commit -qm init ) 2>/dev/null
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run plan h1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "deploy plan passes on a clean deploy repo" || bad "deploy plan passes on a clean deploy repo" "rc=$rc $out"
printf 'dirty\n' >> "$dp/repo/hosts/h1/instances/a1/env"
env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run plan h1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "deploy refuses a dirty deploy repo (exit 1)" || bad "deploy refuses a dirty deploy repo (exit 1)" "rc=$rc"
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --force --dry-run plan h1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'uncommitted' <<<"$out" \
	&& ok "--force proceeds on a dirty repo and says so" || bad "--force proceeds on a dirty repo and says so" "rc=$rc $out"
( cd "$dp/repo" && git checkout -q -- hosts/h1/instances/a1/env ) 2>/dev/null
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" plan h1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'a1' <<<"$out" && grep -q '0.1.0' <<<"$out" && grep -q 'restart' <<<"$out" \
	&& ok "plan lists the instances, the version and what will restart" || bad "plan lists the instances, the version and what will restart" "rc=$rc $out"
# plan must never dial the host: a bogus proxy would make any connection attempt fail loudly
printf 'DEPLOY_HOST=user@h1.example.test\nDEPLOY_DIR=/data/agentbox\nAGENTBOX_VERSION=0.1.0\nDEPLOY_SOCKS=127.0.0.1:1\n' > "$dp/repo/hosts/h1/host.env"
( cd "$dp/repo" && git add -A && git -c user.email=t@e.test -c user.name=t commit -qm socks ) 2>/dev/null
env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" plan h1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "plan stays offline even with an unusable proxy" || bad "plan stays offline even with an unusable proxy" "rc=$rc"
printf 'DEPLOY_HOST=user@h1.example.test\nDEPLOY_DIR=/data/agentbox\nAGENTBOX_VERSION=0.1.0\n' > "$dp/repo/hosts/h1/host.env"
( cd "$dp/repo" && git add -A && git -c user.email=t@e.test -c user.name=t commit -qm hostenv ) 2>/dev/null

# deploy actually pushes config: sync a whitelist, derive the remote .env, fix permissions, then
# start containers. All of this must show up in --dry-run output without ever connecting.
cat > "$dp/repo/hosts/h1/docker-compose.yaml" <<'YML'
services:
  a1:
    image: ghcr.io/owner/agentbox:${AGENTBOX_VERSION}
    env_file: [./instances/a1/env]
YML
( cd "$dp/repo" && git add -A && git -c user.email=t@e.test -c user.name=t commit -qm compose ) 2>/dev/null
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run deploy h1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "deploy --dry-run exits 0" || bad "deploy --dry-run exits 0" "rc=$rc $out"
grep -q 'rsync' <<<"$out" && grep -q 'compose' <<<"$out" && grep -q 'chmod 600' <<<"$out" \
	&& ok "dry-run shows rsync, compose and the 0600 step" || bad "dry-run shows rsync, compose and the 0600 step" "$out"
# the transport is a whitelist: nothing from the agentbox source tree may appear in the rsync source
grep -q "$dp/repo/hosts/h1/" <<<"$out" && ! grep -qE 'Dockerfile|entrypoint\.sh|mise\.toml' <<<"$out" \
	&& ok "rsync source is the host directory only, no agentbox source" || bad "rsync source is the host directory only, no agentbox source" "$out"
grep -q 'AGENTBOX_VERSION=0.1.0' <<<"$out" \
	&& ok "the remote .env is derived, not synced" || bad "the remote .env is derived, not synced" "$out"
! grep -qE 'DEPLOY_KEY|DEPLOY_SOCKS|DEPLOY_HOST=' <<<"$out" \
	&& ok "connection fields never reach the remote .env" || bad "connection fields never reach the remote .env" "$out"

group "template hygiene"
for f in "$ROOT"/examples/*/config.toml; do
	n="$(basename "$f")"
	grep -qE '=[[:space:]]*"(sk-[A-Za-z0-9]|cli_[A-Za-z0-9]{10,})' "$f" && bad "${n} has no plaintext secrets" "a value that looks real was found" || ok "${n} has no plaintext secrets"
	grep -qE '^[[:space:]]*allow_from[[:space:]]*=[[:space:]]*"\*"' "$f" && bad "${n} does not use allow_from=\"*\"" "a template must not demonstrate allow-all" || ok "${n} does not use allow_from=\"*\""
	grep -qE '^[[:space:]]*mode[[:space:]]*=[[:space:]]*"bypassPermissions"' "$f" && bad "${n} does not default to bypassPermissions" "the template default should be acceptEdits" || ok "${n} does not default to bypassPermissions"
done
[ -f "$DEMO_ENV" ] && ok "the instance secret template ends in .example" || bad "the instance secret template ends in .example" "missing"
ls "$ROOT"/examples/*/env "$ROOT/.env" >/dev/null 2>&1 && bad "no real env file in the repo" "an env file without .example was found" || ok "no real env file in the repo"

echo
echo "result: PASS=${PASS} FAIL=${FAIL}"
[ "$FAIL" -eq 0 ]
