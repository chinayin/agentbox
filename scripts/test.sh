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
python3 -c 'import tomllib' 2>/dev/null || { echo "Error: python3 >= 3.11 required (tomllib)" >&2; exit 2; }
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

# arm64 builds are deferred, not abandoned (docs/ROADMAP.md row 1): release.yml builds amd64 only
# because emulating arm64 cost 85% of the build. The lock must keep resolving arm64 URLs anyway, so
# that re-enabling is one line in release.yml and not a lock regeneration. Dropping linux-arm64
# from lockfile_platforms would leave the assertion above green while quietly making that true.
grep -q 'lockfile_platforms = \["linux-x64", "linux-arm64"\]' "$ROOT/mise.toml" \
	&& ok "the lock still covers linux-arm64 even though it is not built" \
	|| bad "the lock still covers linux-arm64 even though it is not built" "re-enabling arm64 would need a lock regeneration"

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
work_dir = "${WORK_DIR}"
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
out="$(bash "$dp/skill/scripts/deploy.sh" --repo "$dp/other" --dry-run plan h2 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "$dp/other" <<<"$out" \
	&& ok "flag overrides the deploy skill .env" || bad "flag overrides the deploy skill .env" "rc=$rc $out"
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
# DEPLOY_KEY and DEPLOY_SOCKS must be present here so the "connection fields never reach the remote
# .env" assertion below actually exercises those two patterns, not just DEPLOY_HOST=.
printf 'DEPLOY_HOST=user@h1.example.test\nDEPLOY_DIR=/data/agentbox\nAGENTBOX_VERSION=0.1.0\nDEPLOY_KEY=/tmp/nope.pem\nDEPLOY_SOCKS=127.0.0.1:7890\n' > "$dp/repo/hosts/h1/host.env"
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
grep -q 'rsync' <<<"$out" && grep -q 'docker compose up' <<<"$out" && grep -q 'chmod 600' <<<"$out" \
	&& ok "dry-run shows rsync, compose and the 0600 step" || bad "dry-run shows rsync, compose and the 0600 step" "$out"
# the transport is a whitelist: nothing from the agentbox source tree may appear in the rsync source
grep -q "$dp/repo/hosts/h1/" <<<"$out" && ! grep -qE 'Dockerfile|entrypoint\.sh|mise\.toml' <<<"$out" \
	&& ok "rsync source is the host directory only, no agentbox source" || bad "rsync source is the host directory only, no agentbox source" "$out"
grep -q 'AGENTBOX_VERSION=0.1.0' <<<"$out" \
	&& ok "the remote .env is derived, not synced" || bad "the remote .env is derived, not synced" "$out"
! grep -qE 'DEPLOY_KEY|DEPLOY_SOCKS|DEPLOY_HOST=' <<<"$out" \
	&& ok "connection fields never reach the remote .env" || bad "connection fields never reach the remote .env" "$out"
# a1's env carries ANTHROPIC_AUTH_TOKEN=sk-x; even with -v it must never be echoed to the plan output.
vout="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run -v deploy h1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'sk-x' <<<"$vout" \
	&& ok "instance secrets never appear in dry-run -v output" || bad "instance secrets never appear in dry-run -v output" "rc=$rc $vout"
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run status h1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'compose ps' <<<"$out" \
	&& ok "status dry-run shows compose ps" || bad "status dry-run shows compose ps" "rc=$rc $out"
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run status 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "status without a host exits 1" || bad "status without a host exits 1" "rc=$rc"

# ---------- import-instance skill ----------
# Reverse of new-instance: reads a running bare-metal cc-connect instance and writes the agentbox
# shape into the deploy repo. Fixture is a fake source instance under mktemp; nothing dials out.
group "import-instance skill"
IM_SRC="$ROOT/.claude/skills/import-instance/scripts"
im="$TMP/im"; mkdir -p "$im/skills/import-instance/scripts" "$im/skills/deploy" "$im/repo/hosts/h1/instances" "$im/other/hosts/h2/instances"
cp "$IM_SRC"/* "$im/skills/import-instance/scripts/"
# render.py resolves lock files via ROOT, which the driver derives from its own script path
# (SKILL_DIR/../../..); under this fixture's shallower copy that lands on $TMP, not $ROOT. Mirror
# the real lock files there so the driver's tool-coverage step reads the genuine mise*.lock content.
cp "$ROOT/mise.lock" "$ROOT/mise.claude.lock" "$ROOT/mise.pi.lock" "$TMP/"
printf 'AGENTBOX_IMPORT_SOURCE=user@src.example.test\nAGENTBOX_IMPORT_KEY=~/nope.pem\n' > "$im/skills/import-instance/.env"
printf 'AGENTBOX_DEPLOY_REPO=%s\n' "$im/repo" > "$im/skills/deploy/.env"
printf 'DEPLOY_HOST=user@h1.example.test\nDEPLOY_DIR=/data/agentbox\nAGENTBOX_VERSION=0.2.0\n' > "$im/repo/hosts/h1/host.env"
printf 'DEPLOY_HOST=user@h2.example.test\nDEPLOY_DIR=/data/agentbox\nAGENTBOX_VERSION=0.2.0\n' > "$im/other/hosts/h2/host.env"
IMPORT="$im/skills/import-instance/scripts/import-instance.sh"
bash "$IMPORT" --help >/dev/null 2>&1 && ok "import-instance --help exits 0" || bad "import-instance --help exits 0" ""
out="$(env -u AGENTBOX_IMPORT_SOURCE -u AGENTBOX_DEPLOY_REPO bash "$IMPORT" --dry-run plan /srv/x 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'user@src.example.test' <<<"$out" && grep -q 'collect.sh' <<<"$out" \
	&& ok "import-instance reads the source host from the skill .env and plans an ssh collect" || bad "import-instance reads the source host from the skill .env and plans an ssh collect" "rc=$rc $out"
out="$(AGENTBOX_IMPORT_SOURCE=other@env.example.test bash "$IMPORT" --dry-run plan /srv/x 2>&1)"
grep -q 'other@env.example.test' <<<"$out" && ! grep -q 'src.example.test' <<<"$out" \
	&& ok "environment overrides the import-instance skill .env" || bad "environment overrides the import-instance skill .env" "$out"
out="$(bash "$IMPORT" --source flag@flag.example.test --dry-run plan /srv/x 2>&1)"
grep -q 'flag@flag.example.test' <<<"$out" && ok "flag overrides the import-instance skill .env" || bad "flag overrides the import-instance skill .env" "$out"
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$IMPORT" --dry-run import --host h1 --name x /srv/x 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "$im/repo/hosts/h1/instances/x" <<<"$out" \
	&& ok "import-instance reads the deploy repo path from the deploy skill .env" || bad "import-instance reads the deploy repo path from the deploy skill .env" "rc=$rc $out"
out="$(AGENTBOX_DEPLOY_REPO="$im/other" bash "$IMPORT" --dry-run import --host h2 --name x /srv/x 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "$im/other/hosts/h2" <<<"$out" && ! grep -q "$im/repo" <<<"$out" \
	&& ok "environment overrides the deploy repo path for import-instance" || bad "environment overrides the deploy repo path for import-instance" "rc=$rc $out"
out="$(bash "$IMPORT" --repo "$im/other" --dry-run import --host h2 --name x /srv/x 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "$im/other/hosts/h2" <<<"$out" \
	&& ok "--repo overrides the deploy repo path for import-instance" || bad "--repo overrides the deploy repo path for import-instance" "rc=$rc $out"
mv "$im/skills/import-instance/.env" "$im/skills/import-instance/.env.off"
env -u AGENTBOX_IMPORT_SOURCE bash "$IMPORT" --dry-run plan /srv/x >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "import-instance without any source host exits 1" || bad "import-instance without any source host exits 1" "rc=$rc"
mv "$im/skills/import-instance/.env.off" "$im/skills/import-instance/.env"
env -u AGENTBOX_DEPLOY_REPO bash "$IMPORT" --dry-run import --host nosuch --name x /srv/x >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "import-instance rejects a host missing from the deploy repo (exit 2)" || bad "import-instance rejects a host missing from the deploy repo (exit 2)" "rc=$rc"
bash "$IMPORT" --dry-run import --host h1 /srv/x >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "import without --name exits 1" || bad "import without --name exits 1" "rc=$rc"
bash "$IMPORT" --dry-run import --host h1 --name Bad_Name /srv/x >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "import rejects an invalid instance name (exit 1)" || bad "import rejects an invalid instance name (exit 1)" "rc=$rc"
bash "$IMPORT" --dry-run frobnicate /srv/x >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "import-instance rejects an unknown action (exit 1)" || bad "import-instance rejects an unknown action (exit 1)" "rc=$rc"
[ -f "$ROOT/.claude/skills/import-instance/.env.example" ] && ! grep -v '127\.0\.0\.1' "$ROOT/.claude/skills/import-instance/.env.example" | grep -qE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
	&& ok "import-instance .env.example carries no real address" || bad "import-instance .env.example carries no real address" ""

# Fake source: an instance dir, an owner home with credentials and user skills, a workspace with
# project skills. Values are fixtures and must never show up in any output of the skill.
src="$im/src/inst"; shome="$im/src/home"; sws="$im/src/ws"
mkdir -p "$src" "$shome/.kube" "$shome/.ssh" "$shome/.claude/skills/alpha" "$shome/.claude/skills/beta" "$shome/.agents" \
	"$shome/.config/systemd/user" "$sws/.claude/skills/gamma" "$sws/skills/delta"
cat > "$src/config.toml" <<TOML
language = "zh"

[log]
level = "info"

[[projects]]
name = "src-ops"
admin_from = "ou_fixture_admin"

[projects.agent]
type = "claudecode"

[projects.agent.options]
work_dir = "$sws" # keep this comment
mode = "bypassPermissions"

[projects.agent.options.env]
ANTHROPIC_BASE_URL = "\${ANTHROPIC_BASE_URL}"
ANTHROPIC_AUTH_TOKEN = "\${ANTHROPIC_AUTH_TOKEN}"
ANTHROPIC_MODEL = "vendor/model-x"
GATEWAY_ADMIN_TOKEN = "sk-fixture-secret-in-config"
EXTRA_API_SECRET = 'fixture-single-quoted'
KUBECONFIG = "$shome/.kube/dev.yaml:$shome/.kube/prod.yaml"
HTTPS_PROXY = "http://proxy.example.test:7890"
NO_PROXY = "localhost,127.0.0.1"

[[projects.platforms]]
type = "feishu"

[projects.platforms.options]
app_id = "\${FEISHU_APP_ID}"
app_secret = "\${FEISHU_APP_SECRET}"
allow_from = "ou_fixture_user"
TOML
printf 'FEISHU_APP_ID=cli_fixture\nFEISHU_APP_SECRET=fixture-feishu-secret\nANTHROPIC_BASE_URL=https://gw.example.test\nANTHROPIC_AUTH_TOKEN=sk-fixture-env-secret\nWORK_DIR=%s\n' "$sws" > "$src/.env"
chmod 600 "$src/.env"
printf 'apiVersion: v1\nkind: Config\nfixture-kube-dev\n' > "$shome/.kube/dev.yaml"
printf 'apiVersion: v1\nkind: Config\nfixture-kube-prod\n' > "$shome/.kube/prod.yaml"
printf -- '-----BEGIN FIXTURE KEY-----\nfixture-ssh-private\n-----END FIXTURE KEY-----\n' > "$shome/.ssh/id_fixture"
printf 'ssh-ed25519 AAAAfixture user@host\n' > "$shome/.ssh/id_fixture.pub"
printf 'Host git.example.test\n  IdentityFile ~/.ssh/id_fixture\n' > "$shome/.ssh/config"
printf 'git.example.test ssh-ed25519 AAAAfixture\n' > "$shome/.ssh/known_hosts"
chmod 600 "$shome/.kube"/* "$shome/.ssh/id_fixture"
printf -- '---\nname: alpha\n---\nRuns curl only.\n' > "$shome/.claude/skills/alpha/SKILL.md"
printf -- '---\nname: beta\n---\nRuns kubectl.\n' > "$shome/.claude/skills/beta/SKILL.md"
printf '#!/usr/bin/env bash\ndocker compose up -d\n' > "$shome/.claude/skills/beta/test.sh"
printf '{"skills":{"alpha":{"source":"owner/repo","skillPath":"skills/alpha"}}}\n' > "$shome/.agents/.skill-lock.json"
printf -- '---\nname: gamma\n---\nThis skill shells out to docker at runtime.\n' > "$sws/.claude/skills/gamma/SKILL.md"
printf -- '---\nname: delta\n---\nPure helm.\n' > "$sws/skills/delta/SKILL.md"
printf '[Service]\nExecStart=/usr/lib/node_modules/cc-connect/bin/cc-connect\nEnvironmentFile=%s/.env\nEnvironment="CC_LOG_FILE=/var/log/x"\n' "$src" > "$shome/.config/systemd/user/cc-connect.service"
COLLECT="$im/skills/import-instance/scripts/collect.sh"
inv="$(bash "$COLLECT" --home "$shome" "$src" 2>"$im/collect.err")"; rc=$?
[ "$rc" -eq 0 ] && ok "collect exits 0 on the fixture" || bad "collect exits 0 on the fixture" "rc=$rc $(cat "$im/collect.err")"
grep -q "^home	$shome$" <<<"$inv" && grep -q "^work_dir	$sws$" <<<"$inv" \
	&& ok "collect reports home and work_dir" || bad "collect reports home and work_dir" "$inv"
grep -q '^env_key	FEISHU_APP_SECRET$' <<<"$inv" && ! grep -q 'fixture-feishu-secret' <<<"$inv" \
	&& ok "collect lists .env key names and no values" || bad "collect lists .env key names and no values" ""
grep -q '^kube_file	dev.yaml	' <<<"$inv" && grep -q '^kube_file	prod.yaml	' <<<"$inv" \
	&& ok "collect lists kubeconfig files" || bad "collect lists kubeconfig files" "$inv"
grep -q '^ssh_key	id_fixture$' <<<"$inv" && grep -q '^ssh_pub	id_fixture.pub$' <<<"$inv" && ! grep -qE '^ssh_key	(config|known_hosts)$' <<<"$inv" \
	&& ok "collect tells private keys from public keys, config and known_hosts" || bad "collect tells private keys from public keys, config and known_hosts" "$inv"
! grep -q 'fixture-ssh-private' <<<"$inv" && ! grep -q 'fixture-kube-dev' <<<"$inv" \
	&& ok "collect never prints credential file contents" || bad "collect never prints credential file contents" ""
grep -q '^user_skill	alpha	-$' <<<"$inv" && grep -q '^user_skill	beta	test.sh$' <<<"$inv" && grep -q "^skill_lock	$shome/.agents/.skill-lock.json$" <<<"$inv" \
	&& ok "collect lists user-level skills with docker hits and the skill lock" || bad "collect lists user-level skills with docker hits and the skill lock" "$inv"
grep -q '^ws_skill	.claude/skills/gamma	SKILL.md$' <<<"$inv" && grep -q '^ws_skill	skills/delta	-$' <<<"$inv" \
	&& ok "collect lists workspace skills with their docker hits" || bad "collect lists workspace skills with their docker hits" "$inv"
grep -q '^unit	EnvironmentFile	' <<<"$inv" && grep -q '^unit	Environment	CC_LOG_FILE$' <<<"$inv" \
	&& ok "collect reads the systemd unit keys, not the values" || bad "collect reads the systemd unit keys, not the values" "$inv"
grep -q '^tool	git	' <<<"$inv" && ok "collect reports tool versions" || bad "collect reports tool versions" "$inv"
sed -n '/^__AGENTBOX_CONFIG_BEGIN__$/,/^__AGENTBOX_CONFIG_END__$/p' <<<"$inv" | grep -q '^mode = "bypassPermissions"$' \
	&& ok "collect embeds config.toml between the markers" || bad "collect embeds config.toml between the markers" ""
bash "$COLLECT" --home "$shome" "$im/nosuch" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "collect exits 2 when config.toml is missing" || bad "collect exits 2 when config.toml is missing" "rc=$rc"
# Read-only by construction: no redirection other than to stderr or /dev/null, and none of the
# commands that change a file system. Comment lines are skipped; the help heredoc must avoid them.
hits="$(grep -vE '^[[:space:]]*#' "$IM_SRC/collect.sh" | sed -E 's#2>/dev/null|>/dev/null|>&2|2>&1|</dev/null##g' | grep -E '(^|[^0-9&])>' || true)"
[ -z "$hits" ] && ok "collect.sh has no redirection that could write a file" || bad "collect.sh has no redirection that could write a file" "$hits"
hits="$(grep -vE '^[[:space:]]*#' "$IM_SRC/collect.sh" | grep -nwE 'tee|rm|chmod|chown|systemctl|mkdir|install|mv|cp|truncate|sed -i' || true)"
[ -z "$hits" ] && ok "collect.sh calls no command that writes" || bad "collect.sh calls no command that writes" "$hits"

# plan on the fixture: read-only, offline, and every mapping decision visible in the text
AGENTBOX_IMPORT_SOCKS=127.0.0.1:1 bash "$IMPORT" --local --home "$shome" plan "$src" > "$im/plan.out" 2>"$im/plan.err"; rc=$?
[ "$rc" -eq 0 ] && ok "local plan exits 0 even with an unusable SOCKS proxy (no connection)" || bad "local plan exits 0 even with an unusable SOCKS proxy (no connection)" "rc=$rc $(cat "$im/plan.err")"
plan="$(cat "$im/plan.out")"
for s in '== artifacts' '== config rewrites' '== file credentials' '== skills' '== tools' '== red items'; do
	grep -q "^$s" <<<"$plan" && ok "plan has section '$s'" || bad "plan has section '$s'" ""
done
grep -q 'work_dir.*\${WORK_DIR}' <<<"$plan" && ok "plan rewrites work_dir to \${WORK_DIR}" || bad "plan rewrites work_dir to \${WORK_DIR}" "$plan"
grep -qE 'ANTHROPIC_MODEL.*\$\{ANTHROPIC_MODEL\}.*literal' <<<"$plan" && ok "plan turns a literal into a placeholder carried to env" || bad "plan turns a literal into a placeholder carried to env" "$plan"
grep -qE 'GATEWAY_ADMIN_TOKEN.*secret' <<<"$plan" && ! grep -q 'sk-fixture-secret-in-config' <<<"$plan$(cat "$im/plan.err")" \
	&& ok "plan flags a secret literal in config without printing it" || bad "plan flags a secret literal in config without printing it" "$plan"
grep -qE 'EXTRA_API_SECRET.*secret' <<<"$plan" && ! grep -q 'fixture-single-quoted' <<<"$plan$(cat "$im/plan.err")" \
	&& ok "plan flags a single-quoted secret literal without printing it" || bad "plan flags a single-quoted secret literal without printing it" "$plan"
grep -q 'KUBECONFIG.*/agent/kubeconfig-dev.yaml:/agent/kubeconfig-prod.yaml' <<<"$plan" && ok "plan maps KUBECONFIG to /agent paths" || bad "plan maps KUBECONFIG to /agent paths" "$plan"
grep -qE 'HTTPS_PROXY.*egress' <<<"$plan" && ok "plan warns that proxy values may not apply to the new host" || bad "plan warns that proxy values may not apply to the new host" "$plan"
grep -qE '^ *WORK_DIR.*discard' <<<"$plan" && ok "plan discards .env keys the config does not reference" || bad "plan discards .env keys the config does not reference" "$plan"
grep -q 'id_fixture.*ssh_key' <<<"$plan" && grep -q 'GIT_SSH_COMMAND' <<<"$plan" && ok "plan mounts the first ssh key and wires GIT_SSH_COMMAND" || bad "plan mounts the first ssh key and wires GIT_SSH_COMMAND" "$plan"
grep -qE 'alpha.*/etc/claude-code' <<<"$plan" && grep -qE 'beta.*test.sh' <<<"$plan" && ok "plan routes user skills to the managed layer and lists docker in self-tests" || bad "plan routes user skills to the managed layer and lists docker in self-tests" "$plan"
grep -qE 'gamma.*SKILL.md' <<<"$plan" && sed -n '/^== red items/,$p' <<<"$plan" | grep -q 'gamma' \
	&& ok "docker in a skill's runtime path is a red item" || bad "docker in a skill's runtime path is a red item" "$plan"
sed -n '/^== red items/,$p' <<<"$plan" | grep -q 'bypassPermissions' && ok "bypassPermissions is a red item" || bad "bypassPermissions is a red item" "$plan"
grep -qE '^ *git .*(system|not in lock)' <<<"$plan" && ok "tool table classifies git" || bad "tool table classifies git" "$plan"
grep -qE 'allow_from|admin_from' <<<"$plan" && ok "plan reminds that open_ids are per app" || bad "plan reminds that open_ids are per app" "$plan"
! grep -q 'fixture-feishu-secret' <<<"$plan$(cat "$im/plan.err")" && ! grep -q 'sk-fixture-env-secret' <<<"$plan$(cat "$im/plan.err")" \
	&& ok "plan output carries no value from the source .env" || bad "plan output carries no value from the source .env" ""
# tool coverage against the real lock files: a covered tool and a not-in-lock tool
tinv="$im/tools.inv"; { echo "$inv" | grep -v '^tool	'; printf 'tool\tkubectl\t/usr/bin/kubectl\tClient Version: v1.36.4\ntool\tfoo\t/usr/bin/foo\tfoo 9.9\ntool\tdocker\t/usr/bin/docker\tDocker version 29.7.2\ntool\tcli\t/usr/bin/cli\tcli 1.0\n'; } > "$tinv"
tplan="$(python3 "$IM_SRC/render.py" --inventory "$tinv" --lock "$ROOT/mise.lock" --lock "$ROOT/mise.claude.lock" --name t 2>&1)"
grep -qE '^ *kubectl .*covered' <<<"$tplan" && grep -qE '^ *foo .*not in lock' <<<"$tplan" && sed -n '/^== red items/,$p' <<<"$tplan" | grep -q 'foo' \
	&& ok "tool coverage marks covered and not-in-lock tools, the latter red" || bad "tool coverage marks covered and not-in-lock tools, the latter red" "$tplan"
sed -n '/^== red items/,$p' <<<"$tplan" | grep -q 'docker' && ok "docker on the source is always a red item" || bad "docker on the source is always a red item" "$tplan"
grep -qE '^ *cli .*ambiguous' <<<"$tplan" && grep -q 'cli/cli' <<<"$tplan" && grep -q 'gitlab-org/cli' <<<"$tplan" && sed -n '/^== red items/,$p' <<<"$tplan" | grep -q 'cli' \
	&& ok "an ambiguous tool-name match is flagged, not silently reported as not in lock" || bad "an ambiguous tool-name match is flagged, not silently reported as not in lock" "$tplan"
# multi-line (triple-quoted) TOML strings are passed through untouched, not misparsed
minv="$im/multiline.inv"
{
	printf 'owner\ttester\nuid\t501\nhome\t/home/tester\nwork_dir\t/home/tester/ws\n'
	printf '__AGENTBOX_CONFIG_BEGIN__\n[projects.agent.options]\nwork_dir = "/home/tester/ws"\n\n[projects.agent.options.env]\nNOTE = """\nline1\n"""\n__AGENTBOX_CONFIG_END__\n'
} > "$minv"
mplan="$(python3 "$IM_SRC/render.py" --inventory "$minv" --lock "$ROOT/mise.lock" --name t 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && sed -n '/^== red items/,$p' <<<"$mplan" | grep -q 'NOTE' && ! grep -qE 'NOTE.*\$\{NOTE\}' <<<"$mplan" \
	&& ok "a multi-line TOML string is left to a human, not misparsed as an empty rewrite" || bad "a multi-line TOML string is left to a human, not misparsed as an empty rewrite" "rc=$rc $mplan"
# argparse usage errors and missing files exit clean, no Python traceback
out="$(python3 "$IM_SRC/render.py" --lock "$ROOT/mise.lock" --name t 2>&1 >/dev/null)"; rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == Error:* ]] && ok "render.py without --inventory exits 1 with an Error: line" || bad "render.py without --inventory exits 1 with an Error: line" "rc=$rc $out"
out="$(python3 "$IM_SRC/render.py" --inventory "$im/nosuch.inv" --lock "$ROOT/mise.lock" --name t 2>&1 >/dev/null)"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'Error:' <<<"$out" && ! grep -q 'Traceback' <<<"$out" \
	&& ok "render.py exits 2 on a missing inventory file, no traceback" || bad "render.py exits 2 on a missing inventory file, no traceback" "rc=$rc $out"
# ~/.gnupg keeps its own line and its own reason, distinct from the state-volume note
grep -qE '\.gnupg.*docs/TOOLS\.md' <<<"$plan" && ok "plan explains the .gnupg credential channel separately" || bad "plan explains the .gnupg credential channel separately" "$plan"

# import on the fixture: files land only under the target, secrets only in files, snippet on stdout
touch "$im/marker"; sleep 1
tgt="$im/repo/hosts/h1/instances/srcops"
HOME="$im/fakehome" AGENTBOX_DEPLOY_REPO="$im/repo" bash "$IMPORT" --local --home "$shome" import --host h1 --name srcops "$src" > "$im/import.out" 2>"$im/import.err"; rc=$?
[ "$rc" -eq 0 ] && ok "local import exits 0" || bad "local import exits 0" "rc=$rc $(cat "$im/import.err")"
[ -f "$tgt/config.toml" ] && [ -f "$tgt/env" ] && [ -f "$tgt/kubeconfig-dev.yaml" ] && [ -f "$tgt/kubeconfig-prod.yaml" ] && [ -f "$tgt/ssh_key" ] \
	&& [ -f "$tgt/claude/.claude/skills/alpha/SKILL.md" ] && [ -f "$tgt/claude/.claude/skills/beta/test.sh" ] && [ -f "$tgt/claude/.skill-lock.json" ] \
	&& ok "import writes config, env, credentials and the managed skills layer" || bad "import writes config, env, credentials and the managed skills layer" "$(find "$tgt" 2>/dev/null)"
[ "$(stat -f %Lp "$tgt/env" 2>/dev/null || stat -c %a "$tgt/env")" = 600 ] && [ "$(stat -f %Lp "$tgt/ssh_key" 2>/dev/null || stat -c %a "$tgt/ssh_key")" = 600 ] \
	&& [ "$(stat -f %Lp "$tgt/kubeconfig-dev.yaml" 2>/dev/null || stat -c %a "$tgt/kubeconfig-dev.yaml")" = 600 ] \
	&& ok "env and credential files land as 0600" || bad "env and credential files land as 0600" ""
grep -q '^FEISHU_APP_SECRET=fixture-feishu-secret$' "$tgt/env" && grep -q '^ANTHROPIC_MODEL=vendor/model-x$' "$tgt/env" \
	&& grep -q '^GATEWAY_ADMIN_TOKEN=sk-fixture-secret-in-config$' "$tgt/env" && grep -q '^HTTPS_PROXY=http://proxy.example.test:7890$' "$tgt/env" \
	&& ok "env keeps the source values and gains the lifted literals" || bad "env keeps the source values and gains the lifted literals" "$(sed 's/=.*/=<v>/' "$tgt/env")"
! grep -q '^WORK_DIR=' "$tgt/env" && ok "env drops WORK_DIR" || bad "env drops WORK_DIR" ""
grep -q 'fixture-ssh-private' "$tgt/ssh_key" && grep -q 'fixture-kube-prod' "$tgt/kubeconfig-prod.yaml" \
	&& ok "credential files are copied verbatim" || bad "credential files are copied verbatim" ""
python3 - "$tgt/config.toml" <<'PY' && ok "rewritten config parses and carries the new shape" || bad "rewritten config parses and carries the new shape" "see config.toml"
import sys, tomllib
c = tomllib.load(open(sys.argv[1], "rb")); p = c["projects"][0]; o = p["agent"]["options"]; e = o["env"]
assert o["work_dir"] == "${WORK_DIR}", o["work_dir"]
assert e["ANTHROPIC_MODEL"] == "${ANTHROPIC_MODEL}" and e["GATEWAY_ADMIN_TOKEN"] == "${GATEWAY_ADMIN_TOKEN}"
assert e["KUBECONFIG"] == "/agent/kubeconfig-dev.yaml:/agent/kubeconfig-prod.yaml", e["KUBECONFIG"]
assert e["GIT_SSH_COMMAND"] == "ssh -i /agent/ssh_key -o IdentitiesOnly=yes"
assert e["ANTHROPIC_AUTH_TOKEN"] == "${ANTHROPIC_AUTH_TOKEN}"
assert p["platforms"][0]["options"]["allow_from"] == "ou_fixture_user"
assert c["log"]["level"] == "info" and o["mode"] == "bypassPermissions"
PY
grep -q '^work_dir = "${WORK_DIR}" # keep this comment$' "$tgt/config.toml" && ok "rewrite keeps trailing comments" || bad "rewrite keeps trailing comments" "$(grep work_dir "$tgt/config.toml")"
diff <(grep -vE '^(work_dir|ANTHROPIC_MODEL|GATEWAY_ADMIN_TOKEN|EXTRA_API_SECRET|KUBECONFIG|HTTPS_PROXY|NO_PROXY|GIT_SSH_COMMAND) ' "$src/config.toml") <(grep -vE '^(work_dir|ANTHROPIC_MODEL|GATEWAY_ADMIN_TOKEN|EXTRA_API_SECRET|KUBECONFIG|HTTPS_PROXY|NO_PROXY|GIT_SSH_COMMAND) ' "$tgt/config.toml") >/dev/null \
	&& ok "every line outside the rewritten keys is preserved verbatim" || bad "every line outside the rewritten keys is preserved verbatim" "$(diff "$src/config.toml" "$tgt/config.toml")"
! grep -qE 'fixture-feishu-secret|sk-fixture-env-secret|sk-fixture-secret-in-config|fixture-ssh-private' "$im/import.out" "$im/import.err" \
	&& ok "import prints no secret on stdout or stderr" || bad "import prints no secret on stdout or stderr" ""
stray="$(find "$im" -newer "$im/marker" -type f -not -path "$tgt/*" -not -path "$im/import.*" 2>/dev/null)"
[ -z "$stray" ] && [ ! -e "$im/fakehome" ] && ok "import writes nothing outside the target instance directory" || bad "import writes nothing outside the target instance directory" "$stray"
snip="$(sed -n '/^  # --- add under services: ---/,$p' "$im/import.out")"
grep -q '^  srcops:$' <<<"$snip" && grep -q 'image: ghcr.io/chinayin/agentbox:${AGENTBOX_VERSION}' <<<"$snip" \
	&& grep -q './instances/srcops/kubeconfig-dev.yaml:/agent/kubeconfig-dev.yaml:ro' <<<"$snip" && grep -q './instances/srcops/ssh_key:/agent/ssh_key:ro' <<<"$snip" \
	&& grep -q './instances/srcops/claude:/etc/claude-code:ro' <<<"$snip" && grep -q './workspaces/srcops:/workspace' <<<"$snip" && grep -q 'pids: ' <<<"$snip" \
	&& ok "snippet mounts config, workspace, credentials and the managed layer with the GHCR image" || bad "snippet mounts config, workspace, credentials and the managed layer with the GHCR image" "$snip"
bash "$IMPORT" --local --home "$shome" --repo "$im/repo" import --host h1 --name srcops "$src" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "import refuses an existing target (exit 1)" || bad "import refuses an existing target (exit 1)" "rc=$rc"
# the imported instance satisfies the deploy skill's local validation as-is
env -u AGENTBOX_DEPLOY_REPO bash "$DP_SRC" --repo "$im/repo" --dry-run plan h1 srcops >/dev/null 2>"$im/dp.err"; rc=$?
[ "$rc" -eq 0 ] && ok "deploy plan accepts the imported instance without edits" || bad "deploy plan accepts the imported instance without edits" "rc=$rc $(cat "$im/dp.err")"

group "template hygiene"
for f in "$ROOT"/examples/*/config.toml; do
	n="$(basename "$f")"
	grep -qE '=[[:space:]]*"(sk-[A-Za-z0-9]|cli_[A-Za-z0-9]{10,})' "$f" && bad "${n} has no plaintext secrets" "a value that looks real was found" || ok "${n} has no plaintext secrets"
	grep -qE '^[[:space:]]*allow_from[[:space:]]*=[[:space:]]*"\*"' "$f" && bad "${n} does not use allow_from=\"*\"" "a template must not demonstrate allow-all" || ok "${n} does not use allow_from=\"*\""
	grep -qE '^[[:space:]]*mode[[:space:]]*=[[:space:]]*"bypassPermissions"' "$f" && bad "${n} does not default to bypassPermissions" "the template default should be acceptEdits" || ok "${n} does not default to bypassPermissions"
done
[ -f "$DEMO_ENV" ] && ok "the instance secret template ends in .example" || bad "the instance secret template ends in .example" "missing"
ls "$ROOT"/examples/*/env "$ROOT/.env" >/dev/null 2>&1 && bad "no real env file in the repo" "an env file without .example was found" || ok "no real env file in the repo"

group "workflow invariants"

WFS=("$ROOT"/.github/workflows/*.yml)

# ${github.workflow} inside a concurrency group resolves to the CALLER's workflow name under
# workflow_call, so release.yml calling ci.yml produced two identical groups and the called job
# deadlocked against its own parent run: instant failure, no logs, no ci job. Prefixes stay literal.
hits="$(grep -n -A2 '^concurrency:' "${WFS[@]}" | grep 'group:' | grep 'github\.workflow' || true)"
[ -z "$hits" ] && ok "no concurrency group is keyed on github.workflow" \
	|| bad "no concurrency group is keyed on github.workflow" "use a literal prefix: $hits"

# Even with literal prefixes, the caller and the workflow it calls must not land on the same group.
ci_grp="$(grep -A1 '^concurrency:' "$ROOT/.github/workflows/ci.yml" | sed -n 's/.*group: *//p')"
rel_grp="$(grep -A1 '^concurrency:' "$ROOT/.github/workflows/release.yml" | sed -n 's/.*group: *//p')"
[ -n "$ci_grp" ] && [ -n "$rel_grp" ] && [ "$ci_grp" != "$rel_grp" ] \
	&& ok "ci.yml and release.yml use different concurrency groups" \
	|| bad "ci.yml and release.yml use different concurrency groups" "ci=[$ci_grp] release=[$rel_grp]"

BAKE="$ROOT/docker-bake.hcl"

# A cache export that fails (registry hiccup, a quota refusal, a revoked token) must not fail a
# release whose images already built and pushed.
ct="$(grep -h 'cache-to' "$BAKE" || true)"
bare="$(printf '%s\n' "$ct" | grep -v 'ignore-error=true' | grep 'type=registry' || true)"
[ -n "$ct" ] && [ -z "$bare" ] && ok "every cache-to carries ignore-error=true" \
	|| bad "every cache-to carries ignore-error=true" "cache-to=[$ct] missing=[$bare]"

# The cache ref must never be the image ref: mode=max would write cache blobs over the version tag
# the release just published.
grep -q 'CACHE_TO.*IMAGE\|ref=${IMAGE}' "$BAKE" \
	&& bad "the build cache never writes to the published image ref" "cache-to derives from IMAGE" \
	|| ok "the build cache never writes to the published image ref"

# Private packages share the account's Packages quota and a refused write degrades to a warning
# because of ignore-error, so the cache must be switched off while the repository is private.
grep -q 'github.event.repository.private' "$ROOT/.github/workflows/release.yml" \
	&& ok "release.yml disables the cache while the repo is private" \
	|| bad "release.yml disables the cache while the repo is private" "no visibility check found"

# Every bake target must name a stage that exists in the Dockerfile.
bake_targets="$(sed -n 's/^  target *= *"\([a-z0-9-]*\)".*/\1/p' "$BAKE" | sort -u)"
[ -n "$bake_targets" ] || bad "bake targets name real Dockerfile stages" "no target = line found in docker-bake.hcl"
missing=""
for t in $bake_targets; do
	grep -qE "^FROM .* AS ${t}\$" "$DF" || missing="${missing}${t} "
done
[ -n "$bake_targets" ] && [ -z "$missing" ] && ok "bake targets name real Dockerfile stages" \
	|| bad "bake targets name real Dockerfile stages" "not a stage in the Dockerfile: ${missing}"

# bake auto-loads docker-compose.yaml when no -f is given, and that file's env_file is gitignored,
# so every invocation must be explicit or it breaks on a clean clone.
callers="$(grep -rn 'buildx bake' "$ROOT/Makefile" "${WFS[@]}" | grep -v '\-f docker-bake.hcl' | grep -v '^\s*#' || true)"
[ -z "$callers" ] && ok "every buildx bake invocation passes -f" \
	|| bad "every buildx bake invocation passes -f" "$callers"

# Bake populates variables from the environment, so a variable named after a common shell variable
# silently absorbs it. A developer's HTTPS_PROXY on 127.0.0.1 would point at the build container.
captured="$(grep -nE '^variable "(HTTP_PROXY|HTTPS_PROXY|NO_PROXY|http_proxy|https_proxy|no_proxy|PATH|HOME|USER)"' "$BAKE" || true)"
[ -z "$captured" ] && ok "no bake variable is named after a common environment variable" \
	|| bad "no bake variable is named after a common environment variable" "prefix it with BUILD_: $captured"

# release.yml runs the gate by calling ci.yml, so ci.yml must keep offering workflow_call.
grep -q '^  workflow_call:' "$ROOT/.github/workflows/ci.yml" \
	&& ok "ci.yml is callable by release.yml (workflow_call)" \
	|| bad "ci.yml is callable by release.yml (workflow_call)" "release.yml's needs: ci would never start"

group "shell standards"

# Every shell script in the repo, gitignored skill .env files excluded (they hold no code).
SHELLS=("$ROOT/entrypoint.sh" "$ROOT"/scripts/*.sh "$ROOT"/.claude/skills/*/scripts/*.sh)

# gox-code-rules:shell -- a bare $VAR immediately followed by a non-ASCII byte is read as part of
# the variable name: with `set -u` the script dies, without it the value silently vanishes. It only
# bites on paths that print a localized or symbol-bearing string, so it survives every smoke test.
# Under LC_ALL=C, [^ -~] is exactly "not printable ASCII"; tab is excluded so indentation is ignored.
hits="$(LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^\t -~]' "${SHELLS[@]}" 2>/dev/null || true)"
[ -z "$hits" ] && ok "no bare \$VAR is followed by a non-ASCII byte" \
	|| bad "no bare \$VAR is followed by a non-ASCII byte" "brace them as \${VAR}: $hits"

# The status prefix has flip-flopped between `error:`, `错误:` and `Error:`. gox-code-rules:shell
# settles it: capitalized and English, so tools can grep, diff and paste it. Pin it here.
# The pattern is assembled from ${q} so this line does not match itself -- a self-matching
# assertion would fail forever and teach nothing.
q='"'
pat="${q}error: |${q}warning: |${q}ERR: |${q}WARN: |${q}错误: |${q}警告: "
hits="$(grep -rnE "${pat}" "${SHELLS[@]}" 2>/dev/null || true)"
[ -z "$hits" ] && ok "status output uses the Error:/Warning: prefixes" \
	|| bad "status output uses the Error:/Warning: prefixes" "$hits"

for f in "${SHELLS[@]}"; do
	n="${f#"$ROOT"/}"
	[ "$(head -1 "$f")" = "#!/usr/bin/env bash" ] && ok "${n} has the standard shebang" \
		|| bad "${n} has the standard shebang" "$(head -1 "$f")"
done

# test.sh is the documented exception: a failing assertion is a counted result, not a fatal error.
grep -q '^set -euo pipefail$' "$ENTRY" && ok "entrypoint.sh sets -euo pipefail" \
	|| bad "entrypoint.sh sets -euo pipefail" "missing"
grep -q '^set -uo pipefail$' "$ROOT/scripts/test.sh" && ok "test.sh sets -uo pipefail (no -e)" \
	|| bad "test.sh sets -uo pipefail (no -e)" "a failing assertion must not abort the run"

echo
echo "result: PASS=${PASS} FAIL=${FAIL}"
[ "$FAIL" -eq 0 ]
