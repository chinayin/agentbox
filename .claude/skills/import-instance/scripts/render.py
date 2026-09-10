#!/usr/bin/env python3
"""Turn a collect.sh inventory into an agentbox instance.

Without --out: print the migration plan on stdout. With --out DIR: also write DIR/config.toml
(rewritten), append the literals lifted out of the config to DIR/env (which must already exist,
copied from the source .env), write the credential/skill copy list to --copy-list, and print the
compose snippet after the plan. Nothing this script prints is a value from the source .env or a
credential file; literals lifted from config.toml are written to env, never printed.
Exit codes: 0 ok / 1 usage error or malformed inventory / 2 lock file or env file missing
"""
import argparse
import os
import re
import sys

BEGIN = "__AGENTBOX_CONFIG_BEGIN__"
END = "__AGENTBOX_CONFIG_END__"
SECRET_NAME = re.compile(r"(TOKEN|SECRET|PASSWORD|PASSWD|_KEY$|^KEY_)", re.I)
PROXY_NAMES = {"HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY"}
KV_LINE = re.compile(r'^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*=\s*)"([^"]*)"(.*)$')
HEADER = re.compile(r"^\s*\[\[?\s*([^\]]+?)\s*\]\]?\s*(#.*)?$")
PLACEHOLDER = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
OPTIONS_TABLE = "projects.agent.options"
ENV_TABLE = "projects.agent.options.env"
SSH_KEY_MOUNT = "/agent/ssh_key"
GIT_SSH_COMMAND = f'ssh -i {SSH_KEY_MOUNT} -o IdentitiesOnly=yes'

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
        hits = [k for k in lock if name.lower() in k.lower().rsplit("/", 1)[-1]]
        lid = hits[0] if len(hits) == 1 else None
    if lid is None or lid not in lock:
        return "not in lock", "add it to mise.toml (docs/TOOLCHAIN.md section 4) or drop the dependency"
    lv = lock[lid]
    if major(version) and major(version) == major(lv):
        return "covered", f"lock {lv}"
    return "major differs", f"lock {lv}"


def rewrite(config_lines, recs):
    """Line-level rewrite of the source config. Returns (lines, ctx)."""
    home = field(recs, "home")
    env_keys = [r[0] for r in fields(recs, "env_key")]
    ssh_keys = [r[0] for r in fields(recs, "ssh_key")]
    ctx = {"rewrites": [], "literals": [], "kube": [], "red": [], "notes": [], "mounts": []}
    out, table, env_end = [], None, []
    for i, line in enumerate(config_lines):
        h = HEADER.match(line)
        if h:
            table = h.group(1).strip()
            out.append(line)
            continue
        m = KV_LINE.match(line)
        if not m or table not in (OPTIONS_TABLE, ENV_TABLE):
            if table == OPTIONS_TABLE and re.match(r'^\s*mode\s*=\s*"bypassPermissions"', line):
                ctx["red"].append("mode = bypassPermissions: only with an explicit allow_from list (docs/SECRETS.md section 3)")
            out.append(line)
            continue
        indent, key, eq, val, rest = m.groups()
        if table == OPTIONS_TABLE:
            if key == "work_dir" and val != "${WORK_DIR}":
                out.append(f'{indent}{key}{eq}"${{WORK_DIR}}"{rest}')
                ctx["rewrites"].append((key, val, "${WORK_DIR}", "compose supplies WORK_DIR"))
            else:
                if key == "mode" and val == "bypassPermissions":
                    ctx["red"].append("mode = bypassPermissions: only with an explicit allow_from list (docs/SECRETS.md section 3)")
                out.append(line)
            continue
        # env table
        env_end.append(len(out) + 1)
        ph = PLACEHOLDER.fullmatch(val)
        if ph:
            if ph.group(1) not in env_keys:
                ctx["red"].append(f"{key}: placeholder ${{{ph.group(1)}}} has no value in the source .env")
            out.append(line)
            continue
        if key == "KUBECONFIG":
            targets = []
            for p in val.split(":"):
                p = p.strip()
                if not p:
                    continue
                src = p.replace("~", home, 1) if p.startswith("~") else p
                base = os.path.basename(src)
                targets.append(f"/agent/kubeconfig-{base}")
                ctx["kube"].append((src, f"kubeconfig-{base}"))
                ctx["mounts"].append((f"kubeconfig-{base}", f"/agent/kubeconfig-{base}"))
            new = ":".join(targets)
            out.append(f'{indent}{key}{eq}"{new}"{rest}')
            ctx["rewrites"].append((key, "<paths>", new, "each file mounted :ro under /agent"))
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
    if ssh_keys:
        ctx["mounts"].append(("ssh_key", SSH_KEY_MOUNT))
        if env_end:
            pos = env_end[-1]
            out.insert(pos, f'GIT_SSH_COMMAND = "{GIT_SSH_COMMAND}"')
            ctx["rewrites"].append(("GIT_SSH_COMMAND", "-", GIT_SSH_COMMAND, "added: git uses the mounted key"))
        else:
            ctx["red"].append("ssh key found but the config has no [projects.agent.options.env] table; add GIT_SSH_COMMAND by hand")
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
    for src, dst in ctx["kube"]:
        L.append(f"  {src:<44} {dst + ' (0600)':<44} bind mount /agent/{dst}:ro")
    ssh_keys = [r[0] for r in fields(recs, "ssh_key")]
    for i, k in enumerate(ssh_keys):
        if i == 0:
            L.append(f"  {home + '/.ssh/' + k:<44} {'ssh_key (0600)':<44} bind mount /agent/ssh_key:ro")
        else:
            L.append(f"  {home + '/.ssh/' + k:<44} {'-':<44} not mounted: only the first key is; wire others by hand")
    for s in fields(recs, "user_skill"):
        L.append(f"  {home + '/.claude/skills/' + s[0]:<44} {'claude/.claude/skills/' + s[0]:<44} bind mount /etc/claude-code:ro")
    lock_path = field(recs, "skill_lock")
    if lock_path:
        L.append(f"  {lock_path:<44} {'claude/.skill-lock.json':<44} for npx skills update")
    for s in fields(recs, "ws_skill"):
        L.append(f"  {'<work_dir>/' + s[0]:<44} {'-':<44} stays in the workspace")
    L.append(f"  {'~/.claude.json, sessions, ~/.gnupg':<44} {'-':<44} not migrated: state volume starts empty")
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
    if not ctx["kube"] and not ssh_keys:
        L.append("  none found")
    for src, dst in ctx["kube"]:
        L.append(f"  {src} -> {dst}  chmod 600; deploy chowns it to UID 1000 on the host")
    if ssh_keys:
        L.append(f"  {home}/.ssh/{ssh_keys[0]} -> ssh_key  chmod 600; GIT_SSH_COMMAND points git at {SSH_KEY_MOUNT}")
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
        L.append(skill_line(s[0], "user level -> managed layer /etc/claude-code", s[1] if len(s) > 1 else "-"))
    for s in fields(recs, "ws_skill"):
        L.append(skill_line(s[0], "workspace", s[1] if len(s) > 1 else "-"))
    L.append("")
    L.append("== tools")
    L.append(f"  {'tool':<12} {'source':<40} {'result':<14} detail")
    for t in fields(recs, "tool"):
        name_, path, ver = (t + ["", "", ""])[:3]
        res, detail = coverage(name_, ver, lock)
        L.append(f"  {name_:<12} {ver[:40]:<40} {res:<14} {detail}")
        if res in ("not in lock", "not in image"):
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
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--inventory", required=True)
    ap.add_argument("--lock", action="append", default=[])
    ap.add_argument("--name", required=True)
    ap.add_argument("--host", default="")
    ap.add_argument("--image", default="ghcr.io/chinayin/agentbox")
    ap.add_argument("--out")
    ap.add_argument("--copy-list")
    a = ap.parse_args()
    if not a.lock:
        die("at least one --lock is required")
    with open(a.inventory, encoding="utf-8") as fh:
        recs, config = parse_inventory(fh.read())
    lock = load_lock(a.lock)
    new_config, ctx = rewrite(config, recs)
    plan = build_plan(recs, ctx, lock, a.host, a.name)
    if a.out:
        write_out(a, recs, new_config, ctx)   # Task 4
    sys.stdout.write(plan)
    if a.out:
        sys.stdout.write(snippet(a, recs, ctx))  # Task 4


def write_out(a, recs, new_config, ctx):
    die("--out is not implemented yet")


def snippet(a, recs, ctx):
    return ""


if __name__ == "__main__":
    main()
