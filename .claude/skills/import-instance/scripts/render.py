#!/usr/bin/env python3
"""Turn a collect.sh inventory into an agentbox instance.

Without --out: print the migration plan on stdout. With --out DIR: also write DIR/config.toml
(rewritten), append the literals lifted out of the config to DIR/env (which must already exist,
copied from the source .env), write the credential/skill copy list to --copy-list, and write
DIR/docker-compose.yaml from the --template file (examples/demo/docker-compose.yaml). Nothing this
script prints is a value from the source .env or a credential file; literals lifted from
config.toml are written to env, never printed.
Exit codes: 0 ok / 1 usage error or malformed inventory / 2 inventory, lock or env file missing
"""
import argparse
import os
import re
import sys

BEGIN = "__AGENTBOX_CONFIG_BEGIN__"
END = "__AGENTBOX_CONFIG_END__"
SECRET_NAME = re.compile(r"(^|_)(TOKEN|SECRET|PASSWORD|PASSWD)(_|$)|_KEY$|^KEY_", re.I)
PROXY_NAMES = {"HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY"}
KV_LINE = re.compile(r'^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*=\s*)(?:"([^"]*)"|\'([^\']*)\')(.*)$')
# A TOML multi-line (triple-quoted) string opening: key = """ or key = '''. The value, and the
# closing delimiter, may be on the same line or several lines later; either way it is not rewritten.
TRIPLE_OPEN = re.compile(r'^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*=\s*)("""|\'\'\')(.*)$')
HEADER = re.compile(r"^\s*\[\[?\s*([^\]]+?)\s*\]\]?\s*(#.*)?$")
PLACEHOLDER = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
OPTIONS_TABLE = "projects.agent.options"
ENV_TABLE = "projects.agent.options.env"
# The container's HOME (entrypoint.sh mount contract: /state, "HOME points here"). The declared
# home layer (instances/<name>/home/) is copied there at every start, so a source path under the
# owner's home becomes the same path under CONTAINER_HOME.
CONTAINER_HOME = "/state"

# binary name -> lock tool id (backend prefix stripped). Unlisted names fall through to a
# substring match on the lock id; SYSTEM tools ship with the base image and are not lock-tracked.
LOCK_ALIAS = {
    "kubectl": "kubernetes/kubernetes/kubectl", "helm": "helm/helm", "helmfile": "helmfile/helmfile",
    "kustomize": "kubernetes-sigs/kustomize", "gh": "cli/cli", "glab": "gitlab-org/cli",
    "aws": "aws/aws-cli", "aliyun": "aliyun/aliyun-cli", "jq": "jqlang/jq", "rg": "BurntSushi/ripgrep",
    "fd": "sharkdp/fd", "uv": "astral-sh/uv", "claude": "anthropics/claude-code",
    "cc-connect": "chenhg5/cc-connect", "pi": "earendil-works/pi", "cloudflared": "cloudflare/cloudflared",
    "node": "node", "go": "go", "python3": "python",
}
SYSTEM_TOOLS = {"git", "gpg", "npm", "pip3", "curl", "mise"}
VERSION_RE = re.compile(r"(\d+)(?:\.(\d+))?(?:\.(\d+))?")


def die(msg, code=1):
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(code)


class ArgParser(argparse.ArgumentParser):
    """argparse's own error() prints a usage banner and exits 2; the contract for this script is
    an Error: line on stderr and exit 1, matching every other usage failure it can raise."""

    def error(self, message):
        print(f"Error: {message}", file=sys.stderr)
        sys.exit(1)


def parse_inventory(text):
    recs, config, in_cfg = [], [], False
    for line in text.splitlines():
        if in_cfg:
            if line == END:
                in_cfg = False
            else:
                config.append(line)
            continue
        if line == BEGIN:
            in_cfg = True
            continue
        if not line.strip():
            continue
        recs.append(line.split("\t"))
    if in_cfg or not config:
        die("malformed inventory: config markers missing or unterminated")
    return recs, config


def field(recs, kind, default=""):
    for r in recs:
        if r[0] == kind:
            return r[1] if len(r) > 1 else default
    return default


def fields(recs, kind):
    return [r[1:] for r in recs if r[0] == kind]


def load_lock(paths):
    versions = {}
    for p in paths:
        if not os.path.isfile(p):
            die(f"lock file not found: {p}", 2)
        cur = None
        with open(p, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r'^\[\[tools\."?([^"\]]+)"?\]\]', line.strip())
                if m:
                    cur = m.group(1).split(":", 1)[-1]
                    continue
                m = re.match(r'^version\s*=\s*"([^"]+)"', line.strip())
                if m and cur and cur not in versions:
                    versions[cur] = m.group(1)
    return versions


def major(v):
    m = VERSION_RE.search(v or "")
    return m.group(1) if m else None


def coverage(name, version, lock):
    if name == "docker":
        return "not in image", "docker is not available inside the container (no socket, by design)"
    if name in SYSTEM_TOOLS:
        return "system", "ships with the base image; not lock-tracked"
    lid = LOCK_ALIAS.get(name)
    if lid is None:
        hits = sorted(k for k in lock if name.lower() in k.lower().rsplit("/", 1)[-1])
        if len(hits) > 1:
            candidates = ", ".join(f"{k} ({lock[k]})" for k in hits)
            return "ambiguous", f"matches {candidates}; pick one explicitly in mise.toml (docs/TOOLCHAIN.md section 4)"
        lid = hits[0] if hits else None
    if lid is None or lid not in lock:
        return "not in lock", "add it to mise.toml (docs/TOOLCHAIN.md section 4) or drop the dependency"
    lv = lock[lid]
    if not major(version):
        return "unknown", "version probe failed on the source; check by hand"
    if major(version) == major(lv):
        return "covered", f"lock {lv}"
    return "major differs", f"lock {lv}"


def home_layer(recs):
    """(source path, target under the instance directory) for every file of the owner's ~/.ssh and
    ~/.kube that the inventory lists. They land in home/ laid out like ~ (docs/CREDENTIALS.md
    section 2); known_hosts and authorized_keys were already left out by collect.sh."""
    home = field(recs, "home")
    rows = []
    for kind, sub in (("ssh_key", ".ssh"), ("ssh_pub", ".ssh"), ("ssh_config", ".ssh"), ("kube_file", ".kube")):
        for r in fields(recs, kind):
            rows.append((f"{home}/{sub}/{r[0]}", f"home/{sub}/{r[0]}"))
    return rows


def rewrite(config_lines, recs):
    """Line-level rewrite of the source config. Returns (lines, ctx)."""
    home = field(recs, "home")
    env_keys = [r[0] for r in fields(recs, "env_key")]
    ssh_keys = [r[0] for r in fields(recs, "ssh_key")]
    ctx = {"rewrites": [], "literals": [], "red": [], "notes": [], "home": home_layer(recs)}
    out, table, env_end = [], None, []
    n = len(config_lines)
    i = 0
    while i < n:
        line = config_lines[i]
        h = HEADER.match(line)
        if h:
            table = h.group(1).strip()
            out.append(line)
            i += 1
            continue
        if table in (OPTIONS_TABLE, ENV_TABLE):
            tm = TRIPLE_OPEN.match(line)
            if tm:
                # Multi-line TOML string: pass the opening line and everything through the closing
                # delimiter (same line or several lines later) through verbatim; flag it for a human.
                mkey, delim, rest_of_line = tm.group(2), tm.group(4), tm.group(5)
                block = [line]
                j = i
                closed = delim in rest_of_line
                while not closed and j + 1 < n:
                    j += 1
                    block.append(config_lines[j])
                    closed = delim in config_lines[j]
                out.extend(block)
                ctx["red"].append(f"{mkey}: multi-line string is not rewritten; convert it by hand")
                i = j + 1
                continue
        m = KV_LINE.match(line)
        if not m or table not in (OPTIONS_TABLE, ENV_TABLE):
            if table == OPTIONS_TABLE and re.match(r'^\s*mode\s*=\s*"bypassPermissions"', line):
                ctx["red"].append("mode = bypassPermissions: only with an explicit allow_from list (docs/CREDENTIALS.md section 4)")
            out.append(line)
            i += 1
            continue
        indent, key, eq, val_dq, val_sq, rest = m.groups()
        val = val_dq if val_dq is not None else val_sq
        if table == OPTIONS_TABLE:
            if key == "work_dir" and val != "${WORK_DIR}":
                out.append(f'{indent}{key}{eq}"${{WORK_DIR}}"{rest}')
                ctx["rewrites"].append((key, val, "${WORK_DIR}", "compose supplies WORK_DIR"))
            else:
                if key == "mode" and val == "bypassPermissions":
                    ctx["red"].append("mode = bypassPermissions: only with an explicit allow_from list (docs/CREDENTIALS.md section 4)")
                out.append(line)
            i += 1
            continue
        # env table
        env_end.append(len(out) + 1)
        ph = PLACEHOLDER.fullmatch(val)
        if ph:
            if ph.group(1) not in env_keys:
                ctx["red"].append(f"{key}: placeholder ${{{ph.group(1)}}} has no value in the source .env")
            out.append(line)
            i += 1
            continue
        if key == "KUBECONFIG":
            # Every file it names lands in home/.kube/ and is read from CONTAINER_HOME/.kube/. A
            # single file named config is kubectl's default and needs no variable at all.
            targets = []
            for p in val.split(":"):
                p = p.strip()
                if not p:
                    continue
                src = p.replace("~", home, 1) if p.startswith("~") else p
                base = os.path.basename(src)
                if not any(s == src for s, _ in ctx["home"]):
                    ctx["home"].append((src, f"home/.kube/{base}"))
                targets.append(f"{CONTAINER_HOME}/.kube/{base}")
            if targets == [f"{CONTAINER_HOME}/.kube/config"]:
                ctx["rewrites"].append((key, "<path>", "-", "dropped: ~/.kube/config is the default path"))
                i += 1
                continue
            new = ":".join(targets)
            out.append(f'{indent}{key}{eq}"{new}"{rest}')
            ctx["rewrites"].append((key, "<paths>", new, "files land in home/.kube/, read from the copied home"))
            i += 1
            continue
        if key == "GIT_SSH_COMMAND" and home and f"{home}/" in val:
            # The source pins a key by absolute path under its home; the same file sits under
            # CONTAINER_HOME after the home layer is applied. Rewritten in place, never lifted to env.
            new = val.replace(f"{home}/", f"{CONTAINER_HOME}/")
            out.append(f'{indent}{key}{eq}"{new}"{rest}')
            ctx["rewrites"].append((key, "<path>", new, "rewritten: the key is read from the copied home"))
            i += 1
            continue
        note = "literal carried to env"
        if SECRET_NAME.search(key):
            note = "secret literal was hard-coded in config; moved to env"
            ctx["red"].append(f"{key}: a secret was hard-coded in the source config.toml; it now lives in env only")
        elif key.upper() in PROXY_NAMES:
            note = "literal carried to env; egress on the new host may differ, confirm before keeping"
        out.append(f'{indent}{key}{eq}"${{{key}}}"{rest}')
        ctx["rewrites"].append((key, "<literal>", f"${{{key}}}", note))
        ctx["literals"].append((key, val))
        i += 1
    # A key with a non-default name is only found through .ssh/config or GIT_SSH_COMMAND.
    default_names = {"id_rsa", "id_ecdsa", "id_ed25519", "id_ed25519_sk", "id_ecdsa_sk", "id_dsa"}
    odd = [k for k in ssh_keys if k not in default_names]
    if odd and not fields(recs, "ssh_config") and not any(k == "GIT_SSH_COMMAND" for k, *_ in ctx["rewrites"]):
        ctx["red"].append(f"ssh key {', '.join(odd)}: non-default name, no .ssh/config and no GIT_SSH_COMMAND names it; add a Host entry to home/.ssh/config")
    # placeholders after rewrite decide what the env must supply
    needed = set()
    for line in out:
        needed.update(PLACEHOLDER.findall(line))
    needed.discard("WORK_DIR")
    literal_keys = {k for k, _ in ctx["literals"]}
    ctx["discard"] = [k for k in env_keys if k not in needed]
    ctx["missing"] = sorted(k for k in needed if k not in env_keys and k not in literal_keys)
    for k in ctx["missing"]:
        ctx["red"].append(f"{k}: referenced by config but supplied by neither the source .env nor a lifted literal")
    if any(re.match(r'^\s*allow_from\s*=\s*"\*"', l) for l in out):
        ctx["red"].append('allow_from = "*": anyone who can message the bot can drive the agent')
    if any(re.match(r'^\s*(allow_from|admin_from)\s*=', l) for l in out):
        ctx["notes"].append("allow_from / admin_from kept verbatim: open_id is per user x app; re-take them if the chat app changes")
    return out, ctx


def build_plan(recs, ctx, lock, host, name):
    home = field(recs, "home")
    L = []
    target = f"hosts/{host}/instances/{name}" if host else f"instances/{name}"
    L.append(f"import plan: {field(recs, 'work_dir') or '<source>'} -> {target}")
    L.append(f"source owner: {field(recs, 'owner')} (uid {field(recs, 'uid')}), home {home}")
    for u in fields(recs, "unit"):
        if u[0] in ("ExecStart", "EnvironmentFile"):
            L.append(f"source unit: {u[0]}={u[1]}")
    L.append("")
    L.append("== artifacts")
    L.append(f"  {'source':<44} {'target':<44} via")
    L.append(f"  {'config.toml':<44} {'config.toml (rewritten)':<44} bind mount /agent/config.toml:ro")
    L.append(f"  {'.env':<44} {'env (values verbatim, 0600)':<44} env_file")
    for src, dst in ctx["home"]:
        L.append(f"  {src:<44} {dst + ' (0600)':<44} home layer, copied into ~ at every start")
    lock_path = field(recs, "skill_lock")
    for s in fields(recs, "user_skill"):
        dst = "-" if lock_path else "(no manifest)"
        L.append(f"  {home + '/.claude/skills/' + s[0]:<44} {dst:<44} not copied: reinstalled from the manifest on first start")
    if lock_path:
        L.append(f"  {lock_path:<44} {'skills-lock.json':<44} bind mount /agent/skills-lock.json:ro")
    for s in fields(recs, "ws_skill"):
        L.append(f"  {'<work_dir>/' + s[0]:<44} {'-':<44} stays in the workspace")
    L.append(f"  {'~/.claude.json, sessions':<44} {'-':<44} not migrated: state volume starts empty")
    L.append(f"  {'~/.gnupg':<44} {'-':<44} not migrated: signing keys, if needed, go through the docs/CREDENTIALS.md credential channel")
    wd = field(recs, "work_dir")
    remote = field(recs, "git_remote")
    if remote:
        L.append(f"  {wd:<44} {'workspaces/' + name + '/':<44} clone {remote} on the host as UID 1000 (manual)")
    else:
        L.append(f"  {wd:<44} {'workspaces/' + name + '/':<44} not a git repo: rsync once, owner UID 1000 (manual)")
    L.append("")
    L.append("== config rewrites")
    for key, old, new, note in ctx["rewrites"]:
        L.append(f"  {key:<28} {old:<20} -> {new:<44} {note}")
    for k in ctx["discard"]:
        L.append(f"  {k:<28} {'(.env only)':<20} -> {'-':<44} discard: not referenced by config")
    L.append("")
    L.append("== file credentials")
    if not ctx["home"]:
        L.append("  none found")
    for src, dst in ctx["home"]:
        L.append(f"  {src} -> {dst}  chmod 600; deploy chowns it to UID 1000; the entrypoint copies it to {CONTAINER_HOME}/{dst[len('home/'):]}")
    L.append("")
    L.append("== skills")
    def skill_line(name_, where, hits):
        if hits == "-":
            return f"  {name_:<28} {where}, no docker"
        if "SKILL.md" in hits.split(","):
            ctx["red"].append(f"skill {name_}: SKILL.md mentions docker; there is no docker inside the container")
            return f"  {name_:<28} {where}, docker in runtime path ({hits})"
        return f"  {name_:<28} {where}, docker only in self-tests ({hits}): those tests cannot run inside the container"
    for s in fields(recs, "user_skill"):
        L.append(skill_line(s[0], "user level -> reinstalled from the manifest into /state", s[1] if len(s) > 1 else "-"))
    for s in fields(recs, "ws_skill"):
        L.append(skill_line(s[0], "workspace", s[1] if len(s) > 1 else "-"))
    for s in fields(recs, "skill_cred"):
        ctx["red"].append(f"skill {s[0]} carries a credential-looking file ({s[1]}); review it before committing the deploy repo")
    L.append("")
    L.append("== tools")
    L.append(f"  {'tool':<12} {'source':<40} {'result':<14} detail")
    for t in fields(recs, "tool"):
        name_, path, ver = (t + ["", "", ""])[:3]
        res, detail = coverage(name_, ver, lock)
        L.append(f"  {name_:<12} {ver[:40]:<40} {res:<14} {detail}")
        if res in ("not in lock", "not in image", "ambiguous"):
            ctx["red"].append(f"tool {name_}: {res}; {detail}")
    L.append("")
    L.append("== red items")
    seen = set()
    for r in ctx["red"] + ctx["notes"]:
        if r not in seen:
            seen.add(r)
            L.append(f"  - {r}")
    if not seen:
        L.append("  none")
    return "\n".join(L) + "\n"


def main():
    ap = ArgParser(add_help=True)
    ap.add_argument("--inventory", required=True)
    ap.add_argument("--lock", action="append", default=[])
    ap.add_argument("--name", required=True)
    ap.add_argument("--host", default="")
    ap.add_argument("--image", default="ghcr.io/chinayin/agentbox")
    ap.add_argument("--out")
    ap.add_argument("--copy-list")
    ap.add_argument("--template")
    a = ap.parse_args()
    if not a.lock:
        die("at least one --lock is required")
    if not os.path.isfile(a.inventory):
        die(f"inventory file not found: {a.inventory}", 2)
    with open(a.inventory, encoding="utf-8") as fh:
        recs, config = parse_inventory(fh.read())
    lock = load_lock(a.lock)
    new_config, ctx = rewrite(config, recs)
    plan = build_plan(recs, ctx, lock, a.host, a.name)
    if a.out:
        write_out(a, recs, new_config, ctx)
    sys.stdout.write(plan)


def write_out(a, recs, new_config, ctx):
    out = a.out
    if not a.copy_list:
        die("--copy-list is required with --out")
    if not a.template:
        die("--template is required with --out")
    if not os.path.isfile(a.template):
        die(f"compose template not found: {a.template}", 2)
    env_path = os.path.join(out, "env")
    if not os.path.isfile(env_path):
        die(f"{env_path} must exist before rendering (copied from the source .env)", 2)
    text = "\n".join(new_config) + "\n"
    try:
        import tomllib
        tomllib.loads(text)
    except ModuleNotFoundError:
        print("Warning: python3 < 3.11, skipping the TOML parse check", file=sys.stderr)
    except Exception as exc:  # noqa: BLE001 - report and stop, whatever tomllib raised
        die(f"rewritten config.toml does not parse: {exc}")
    with open(os.path.join(out, "config.toml"), "w", encoding="utf-8") as fh:
        fh.write(text)
    # env: keep the source file, drop unreferenced keys, append lifted literals
    with open(env_path, encoding="utf-8") as fh:
        src_lines = fh.read().splitlines()
    drop = set(ctx["discard"])
    kept = []
    for line in src_lines:
        m = re.match(r"^(?:export )?([A-Za-z_][A-Za-z0-9_]*)=", line)
        if m and m.group(1) in drop:
            continue
        kept.append(line)
    if ctx["literals"]:
        kept.append("")
        kept.append("# Lifted from the source config.toml by import-instance; config now references ${NAME}.")
        for k, v in ctx["literals"]:
            kept.append(f"{k}={v}")
    with open(env_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(kept).rstrip("\n") + "\n")
    os.chmod(env_path, 0o600)
    # copy list for the driver: credentials as 0600 files, skills as directories
    rows = []
    for src, dst in ctx["home"]:
        rows.append(("cred", src, dst))
    # User-level skills are not copied: the manifest is what the instance carries, and the
    # entrypoint installs from it into the state volume (docs/SKILLS.md).
    lock_path = field(recs, "skill_lock")
    if lock_path:
        rows.append(("file", lock_path, "skills-lock.json"))
    with open(a.copy_list, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write("\t".join(r) + "\n")
    with open(os.path.join(out, "docker-compose.yaml"), "w", encoding="utf-8") as fh:
        fh.write(compose(a, recs, ctx))


TEMPLATE_IMAGE = "ghcr.io/chinayin/agentbox"


def compose(a, recs, ctx):
    """The instance's docker-compose.yaml: the demo template renamed, with the skill manifest mount
    added after the cache volume when there is one. File credentials need no mount of their own: the
    template's ./home:/agent/home:ro carries them. The same three substitutions as new-instance's
    scaffold.sh; the indented "# ..." hints are dropped from a generated file."""
    n = a.name
    with open(a.template, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    mounts = []
    if field(recs, "skill_lock"):
        mounts.append("      - ./skills-lock.json:/agent/skills-lock.json:ro")
    out, hits = [], {"service": 0, "container": 0, "workspace": 0, "cache": 0}
    for line in lines:
        if line.startswith("      #"):
            continue
        if line == "  demo:":
            line = f"  {n}:"; hits["service"] += 1
        elif line == "    container_name: agentbox-demo":
            line = f"    container_name: agentbox-{n}"; hits["container"] += 1
        elif line.endswith("/demo:/workspace"):
            line = line[: -len("/demo:/workspace")] + f"/{n}:/workspace"; hits["workspace"] += 1
        elif line.startswith("  image: ") and TEMPLATE_IMAGE in line:
            line = line.replace(TEMPLATE_IMAGE, a.image)
        out.append(line)
        if line == "      - cache:/cache":
            hits["cache"] += 1
            out.extend(mounts)
    missing = [k for k, v in hits.items() if v != 1]
    if missing:
        die(f"compose template {a.template} changed: {', '.join(missing)} line not found exactly once")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    main()
