# 部署仓库落到 `deploy-repo/` 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 部署仓库的约定位置是 agentbox 根下 gitignored 的 `deploy-repo/`，三个技能统一从那里解析路径；`new-instance` 直接把实例写进部署仓库并补齐仓库骨架。

**Architecture:** 三个独立脚本（`deploy.sh`、`import-instance.sh`、`scaffold.sh`）各加一段相同的解析：`--repo` > `AGENTBOX_DEPLOY_REPO` > `<root>/deploy-repo`（存在时），否则退出 2。`deploy` 技能的 `.env` 及加载代码删除。`scaffold.sh` 的目标从 `examples/<name>/` 改为 `<repo>/hosts/<host>/instances/<name>/`，产物是 `env`（0600）而不是 `env.example`，并在 `host.env` / `defaults.env` 缺失时从 `.claude/skills/deploy/references/` 下的两份模板生成。

**Tech Stack:** bash；断言在 `scripts/test.sh`，`make check` 驱动。

**Spec:** `docs/superpowers/specs/2026-09-22-deploy-repo-dir-design.md`

## Global Constraints

- 脚本注释、帮助、报错全英文，`Error:` / `Warning:` 前缀，stdout 只放产物（`gox-code-rules:shell`）。
- 退出码：0 成功 / 1 用法错误或目标已存在 / 2 前置条件缺失。
- 模板只有 `xxxx` 形状的占位值；不出现任何真实地址或密钥（`docs/CREDENTIALS.md` §5）。
- 文档中文，契约文件只写现状；DECISIONS 只增不改。
- 每个任务结束跑 `make check` 必须全绿。

---

### Task 1: `deploy.sh` 解析默认目录，`.env` 退场，模板文件落地

**Files:**
- Create: `.claude/skills/deploy/references/host.env.example`
- Create: `.claude/skills/deploy/references/defaults.env.example`
- Delete: `.claude/skills/deploy/.env.example`
- Modify: `.claude/skills/deploy/scripts/deploy.sh:11-34,62,70-72,120`
- Modify: `.claude/skills/deploy/SKILL.md:14-18`
- Modify: `.claude/skills/deploy/references/deploy-repo.md:1-10,36-52,134-141`
- Test: `scripts/test.sh:680-760`

**Interfaces:**
- Produces: 两份模板文件路径，Task 3 的 scaffold 读它们；`deploy.sh` 在没有 `--repo`、没有环境变量、`<root>/deploy-repo` 不存在时 exit 2 并提到 `deploy-repo`。

- [ ] **Step 1: 改测试夹具布局，让 `ROOT` 落在 `$dp/root`**

`scripts/test.sh` 第 685 行起的 deploy 组，脚本副本放到 `$dp/skill/scripts/`，`ROOT` 会推到 `$TMP/..`。改成真实的目录深度并用软链提供默认仓库：

```bash
dp="$TMP/dp"; dps="$dp/root/.claude/skills/deploy"; mkdir -p "$dps/scripts"; cp "$DP_SRC" "$dps/scripts/"
mkdir -p "$dp/repo/hosts/h1/instances/a1" "$dp/other/hosts/h2/instances/a2"
ln -s "$dp/repo" "$dp/root/deploy-repo"
```

组内所有 `$dp/skill` 替换为 `$dps`（`sed -i '' 's|\$dp/skill|\$dps|g'` 只作用于这一组的行区间，先 `grep -n` 确认没有别的组用 `$dp/skill`）。

- [ ] **Step 2: 改写路径来源的四条断言**

删掉第 743 行 `printf 'AGENTBOX_DEPLOY_REPO=...' > "$dp/skill/.env"` 和第 758 行同样的一行，以及第 759-760 行 `.env.example` 断言。把三条覆盖断言与「无来源」断言改为：

```bash
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dps/scripts/deploy.sh" --dry-run plan h1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "$dp/root/deploy-repo" <<<"$out" \
	&& ok "deploy defaults to <root>/deploy-repo" || bad "deploy defaults to <root>/deploy-repo" "rc=$rc $out"
out="$(AGENTBOX_DEPLOY_REPO="$dp/other" bash "$dps/scripts/deploy.sh" --dry-run plan h2 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "$dp/other" <<<"$out" && ! grep -q "deploy-repo" <<<"$out" \
	&& ok "environment overrides the default deploy repo" || bad "environment overrides the default deploy repo" "rc=$rc $out"
out="$(bash "$dps/scripts/deploy.sh" --repo "$dp/other" --dry-run plan h2 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "$dp/other" <<<"$out" \
	&& ok "flag overrides the default deploy repo" || bad "flag overrides the default deploy repo" "rc=$rc $out"
rm "$dp/root/deploy-repo"
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dps/scripts/deploy.sh" plan h1 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'deploy-repo' <<<"$out" \
	&& ok "deploy without any repo source exits 2 and names deploy-repo" || bad "deploy without any repo source exits 2 and names deploy-repo" "rc=$rc $out"
ln -s "$dp/repo" "$dp/root/deploy-repo"
[ ! -e "$ROOT/.claude/skills/deploy/.env.example" ] && ok "deploy skill has no .env.example (repo path is the deploy-repo directory)" || bad "deploy skill has no .env.example (repo path is the deploy-repo directory)" ""
for f in host.env.example defaults.env.example; do
	[ -f "$ROOT/.claude/skills/deploy/references/$f" ] && ! grep -v '127\.0\.0\.1' "$ROOT/.claude/skills/deploy/references/$f" | grep -qE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
		&& ok "deploy references/$f carries no real address" || bad "deploy references/$f carries no real address" ""
done
```

- [ ] **Step 3: 跑测试确认红**

Run: `bash scripts/test.sh 2>&1 | grep -A3 'deploy skill' | head; bash scripts/test.sh >/dev/null 2>&1; echo rc=$?`
Expected: deploy 组出现 `[FAIL] deploy defaults to <root>/deploy-repo` 等，rc=1。

- [ ] **Step 4: 写两份模板**

`.claude/skills/deploy/references/host.env.example`（内容照搬 `deploy-repo.md` 现有代码块，加注释头）：

```env
# hosts/<host>/host.env: one host of the deploy repo. The top half is read locally by deploy.sh and
# never leaves this machine; only the bottom half is derived into the remote .env.
# Behind a rule-based proxy (Clash) write the host as <ip>.sslip.io and set the alias to the bare ip.
DEPLOY_HOST=root@xxx.xxx.xxx.xxx.sslip.io
DEPLOY_KEY=~/.ssh/xxxx.pem
DEPLOY_HOST_KEY_ALIAS=xxx.xxx.xxx.xxx
DEPLOY_SOCKS=127.0.0.1:7890
DEPLOY_DIR=/data/agentbox

# Derived into the remote .env; nothing else in this file is.
# AGENTBOX_VERSION is optional here: omit it and defaults.env supplies it for the whole fleet.
# AGENTBOX_VERSION=x.x.x
AGENTBOX_PROFILE=global
TZ=UTC
```

`.claude/skills/deploy/references/defaults.env.example`：

```env
# defaults.env at the deploy repo root: the image version every host runs unless its host.env pins
# its own. Pick a tag from https://github.com/chinayin/agentbox/releases.
AGENTBOX_VERSION=x.x.x
```

- [ ] **Step 5: 改 `deploy.sh`**

删掉第 21-32 行的 `.env` 加载循环。第 11-13 行注释改为：

```bash
# The repo path comes from, in order of precedence: --repo, AGENTBOX_DEPLOY_REPO, and the deploy-repo
# directory at the agentbox root (a clone of the private deploy repo, or a symlink to one; gitignored).
# Per-host connection details live in the deploy repo at hosts/<host>/host.env and never in here.
```

第 120 行替换为：

```bash
if [ -z "${REPO}" ]; then
	[ -d "${ROOT}/deploy-repo" ] || pre "no deploy repo: clone or symlink the private deploy repository to ${ROOT}/deploy-repo, or pass --repo (see .claude/skills/deploy/references/deploy-repo.md)"
	REPO="${ROOT}/deploy-repo"
fi
```

usage 里第 62 行改为 `--repo PATH    deploy repository (default: <agentbox root>/deploy-repo, or AGENTBOX_DEPLOY_REPO)`；第 70-72 行那段改为：

```
The deploy repo is the private repository described in references/deploy-repo.md. By default it is
the deploy-repo/ directory at the agentbox root (gitignored; a clone or a symlink). Flags and the
environment win. Per-host connection details live in the deploy repo at hosts/<host>/host.env.
```

- [ ] **Step 6: 跑测试确认绿**

Run: `bash scripts/test.sh >/dev/null 2>&1; echo rc=$?; bash scripts/test.sh 2>&1 | grep FAIL`
Expected: rc=0，无 FAIL。

- [ ] **Step 7: 改 SKILL.md 与 deploy-repo.md**

`SKILL.md` 第 14-18 行「Configuration」首段改为：

```
The deploy repo is the `deploy-repo/` directory at the agentbox root: a clone of the private
repository, or a symlink to one, gitignored either way. `--repo` and `AGENTBOX_DEPLOY_REPO` override
it. If it is missing, do not guess or ask for a path in chat: point the user at
`references/deploy-repo.md` (clone it, or `git init deploy-repo` and let `new-instance` lay out the
skeleton) and stop.
```

`deploy-repo.md`：首段末尾加一段位置说明；`host.env` 与 `defaults.env` 的内嵌代码块换成指向两份模板的链接（`references/host.env.example`、`references/defaults.env.example`），字段解释保留。加一段风险：

```
## Where it lives

Clone it to `deploy-repo/` at the agentbox root (or symlink an existing clone there). The
directory is gitignored, so the two repositories never mix; every skill finds it without
configuration. It is not under `runtime/`: `git clean -fdx` in agentbox deletes `deploy-repo/` too,
and since `deploy` refuses a dirty repo, what that can cost is uncommitted edits, nothing more.
```

- [ ] **Step 8: 删 `.env.example`，跑 `make check`**

```bash
git rm -q .claude/skills/deploy/.env.example
make check
```

Expected: 全绿。`contract consistency` 和 docs-path 断言若指出 `.env.example` 仍被引用，按提示修文档。

- [ ] **Step 9: Commit**

```bash
git add -A .claude/skills/deploy scripts/test.sh
git commit -m "deploy: resolve the deploy repo from <root>/deploy-repo; host.env and defaults.env templates"
```

---

### Task 2: `import-instance` 不再读 `deploy` 的 `.env`

**Files:**
- Modify: `.claude/skills/import-instance/scripts/import-instance.sh:6-8,15,32,77,125`
- Modify: `.claude/skills/import-instance/SKILL.md:12`
- Modify: `.claude/skills/import-instance/.env.example:4`
- Test: `scripts/test.sh:1011-1035`

**Interfaces:**
- Consumes: 无。
- Produces: `import` 动作在无来源时 exit 2 并提到 `deploy-repo`。

- [ ] **Step 1: 改测试夹具**

第 1011 行 `mkdir` 去掉 `"$im/skills/deploy"`；删第 1020 行写 `deploy/.env` 的 printf。夹具的 `ROOT` 是 `$TMP`（注释已说明），在第 1022 行后加：

```bash
ln -s "$im/repo" "$TMP/deploy-repo"
```

第 1033-1035 行断言改名：

```bash
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$IMPORT" --dry-run import --host h1 --name x /srv/x 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "$im/repo/hosts/h1/instances/x" <<<"$out" \
	&& ok "import-instance defaults to <root>/deploy-repo" || bad "import-instance defaults to <root>/deploy-repo" "rc=$rc $out"
```

在第 1046 行「rejects a host missing」前加无来源断言：

```bash
rm "$TMP/deploy-repo"
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$IMPORT" --dry-run import --host h1 --name x /srv/x 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'deploy-repo' <<<"$out" \
	&& ok "import without any repo source exits 2 and names deploy-repo" || bad "import without any repo source exits 2 and names deploy-repo" "rc=$rc $out"
ln -s "$im/repo" "$TMP/deploy-repo"
```

- [ ] **Step 2: 跑测试确认红**

Run: `bash scripts/test.sh 2>&1 | grep FAIL`
Expected: `import without any repo source exits 2 ...` FAIL（现在 exit 1）。

- [ ] **Step 3: 改脚本**

删第 15 行 `DEPLOY_SKILL_DIR=...` 和第 32 行 `load_env_file "${DEPLOY_SKILL_DIR}/.env" AGENTBOX_DEPLOY_REPO`。第 7-8 行注释改为 `The deploy repo path comes from --repo, AGENTBOX_DEPLOY_REPO, or the deploy-repo directory at the agentbox root.`。第 77 行 usage 改为 `--repo DIR           deploy repository (default: <agentbox root>/deploy-repo, or AGENTBOX_DEPLOY_REPO)`。第 125 行替换为：

```bash
	if [ -z "${REPO}" ]; then
		[ -d "${ROOT}/deploy-repo" ] || pre "no deploy repo: clone or symlink the private deploy repository to ${ROOT}/deploy-repo, or pass --repo (see .claude/skills/deploy/references/deploy-repo.md)"
		REPO="${ROOT}/deploy-repo"
	fi
```

- [ ] **Step 4: 跑测试确认绿**

Run: `bash scripts/test.sh >/dev/null 2>&1; echo rc=$?`
Expected: rc=0。

- [ ] **Step 5: 改文档**

`SKILL.md` 第 12 行「部署仓库路径复用 `deploy` 技能的 `.env`（`AGENTBOX_DEPLOY_REPO`），不另配。两个 `.env` 缺任何一个，都指向对应的 `.env.example` 然后停下」改为「部署仓库是 agentbox 根下的 `deploy-repo/`（`deploy` 技能的 `references/deploy-repo.md`），不另配。源主机 `.env` 缺失指向 `.env.example`，`deploy-repo/` 缺失指向 `deploy-repo.md`，然后停下」。`.env.example` 第 4 行改为 `# The deploy repo is deploy-repo/ at the agentbox root (see .claude/skills/deploy/references/deploy-repo.md).`

- [ ] **Step 6: `make check` 并提交**

```bash
make check
git add -A .claude/skills/import-instance scripts/test.sh
git commit -m "import-instance: resolve the deploy repo from <root>/deploy-repo"
```

---

### Task 3: `scaffold.sh` 直接写部署仓库

**Files:**
- Modify: `.claude/skills/new-instance/scripts/scaffold.sh`（整文件）
- Modify: `.claude/skills/new-instance/SKILL.md:1-6,42-70,80-102`
- Modify: `.claude/skills/new-instance/references/checklist.md`
- Test: `scripts/test.sh:601-654`

**Interfaces:**
- Consumes: Task 1 的 `.claude/skills/deploy/references/host.env.example`、`defaults.env.example`。
- Produces: `scaffold.sh [--host H] [--agent pi] [--repo DIR] [--root DIR] [--dry-run] <name>`，写 `<repo>/hosts/<H>/instances/<name>/{docker-compose.yaml,config.toml,env}`。

- [ ] **Step 1: 重写测试组**

第 604-654 行整段替换：

```bash
group "new-instance scaffold"
SCAFFOLD="$ROOT/.claude/skills/new-instance/scripts/scaffold.sh"
sc="$TMP/scaffold"; mkdir -p "$sc/examples" "$sc/.claude/skills/deploy/references" "$sc/deploy-repo"
cp -R "$ROOT/examples/demo" "$sc/examples/"; cp "$ROOT/.gitignore" "$sc/"
cp "$ROOT/.claude/skills/deploy/references/host.env.example" "$ROOT/.claude/skills/deploy/references/defaults.env.example" "$sc/.claude/skills/deploy/references/"
inst="$sc/deploy-repo/hosts/default/instances/data"
if out="$(bash "$SCAFFOLD" --root "$sc" --agent pi data 2>"$sc/err")"; then
	ok "scaffold exits 0 for a fresh name"
else
	bad "scaffold exits 0 for a fresh name" "$(cat "$sc/err")"
fi
[ -z "$out" ] && ok "scaffold prints nothing on stdout (the files are the product)" || bad "scaffold prints nothing on stdout (the files are the product)" "$out"
[ -f "$inst/docker-compose.yaml" ] && [ -f "$inst/config.toml" ] && [ -f "$inst/env" ] && [ ! -e "$inst/env.example" ] \
	&& ok "scaffold writes the instance into deploy-repo/hosts/default/instances/<name> with env, not env.example" \
	|| bad "scaffold writes the instance into deploy-repo/hosts/default/instances/<name> with env, not env.example" "$(ls -A "$inst" 2>/dev/null)"
[ "$(stat -f '%Lp' "$inst/env" 2>/dev/null || stat -c '%a' "$inst/env")" = "600" ] \
	&& ok "scaffolded env is 0600" || bad "scaffolded env is 0600" "$(ls -l "$inst/env")"
[ -f "$sc/deploy-repo/hosts/default/host.env" ] && [ -f "$sc/deploy-repo/defaults.env" ] \
	&& ok "scaffold lays out host.env and defaults.env when the repo lacks them" || bad "scaffold lays out host.env and defaults.env when the repo lacks them" "$(find "$sc/deploy-repo" -maxdepth 3)"
grep -vE '^(#|$)' "$sc/deploy-repo/hosts/default/host.env" "$sc/deploy-repo/defaults.env" | grep -vE '=(root@)?(xxx\.xxx\.xxx\.xxx(\.sslip\.io)?|~/\.ssh/xxxx\.pem|127\.0\.0\.1:7890|/data/agentbox|x\.x\.x|global|UTC)$' | grep -q . \
	&& bad "generated host.env and defaults.env hold placeholders only" "$(grep -vE '^(#|$)' "$sc/deploy-repo/hosts/default/host.env" "$sc/deploy-repo/defaults.env")" \
	|| ok "generated host.env and defaults.env hold placeholders only"
grep -q 'host.env' "$sc/err" && grep -q 'defaults.env' "$sc/err" && grep -q 'instances/data/env' "$sc/err" \
	&& ok "scaffold tells the user which files need values" || bad "scaffold tells the user which files need values" "$(cat "$sc/err")"
python3 -c 'import sys,tomllib; c=tomllib.load(open(sys.argv[1],"rb")); p=c["projects"][0]; assert p["name"]=="data" and p["agent"]["type"]=="pi" and "KUBECONFIG" not in p["agent"]["options"]["env"]' "$inst/config.toml" 2>/dev/null \
	&& ok "scaffolded config.toml parses with name and agent type applied and no path variable" \
	|| bad "scaffolded config.toml parses with name and agent type applied and no path variable" "see $inst/config.toml"
grep -q '^PI_KEY=x' "$inst/env" \
	&& ok "pi scaffold uncomments PI_KEY with a placeholder" || bad "pi scaffold uncomments PI_KEY with a placeholder" ""
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
print("\n".join(sorted(names)))' "$inst/config.toml")"
have="$(grep -oE '^[A-Z_]+=' "$inst/env" | tr -d = | sort -u)"
[ -z "$(comm -23 <(echo "$want") <(echo "$have"))" ] \
	&& ok "every placeholder in the scaffolded config has a line in env" \
	|| bad "every placeholder in the scaffolded config has a line in env" "$(comm -23 <(echo "$want") <(echo "$have") | tr '\n' ' ')"
grep -vE '^(#|$)' "$inst/env" | grep -vE '=(cli_|ou_|sk-)?x+$|=https://[a-z.-]+\.example\.com$' | grep -q . \
	&& bad "scaffolded env holds placeholders only" "$(grep -vE '^(#|$)' "$inst/env" | grep -vE '=(cli_|ou_|sk-)?x+$|example\.com')" \
	|| ok "scaffolded env holds placeholders only"
scf="$inst/docker-compose.yaml"
grep -q 'image: ghcr.io/chinayin/agentbox:${AGENTBOX_VERSION}-pi$' "$scf" \
	&& ok "pi scaffold switches the anchor image to the -pi tag" || bad "pi scaffold switches the anchor image to the -pi tag" "$(grep image: "$scf")"
grep -q '^      - ./home:/agent/home:ro$' "$scf" && [ "$(grep -c '/agent/' "$scf")" -eq 2 ] \
	&& ok "scaffold mounts the home layer and nothing else under /agent besides config.toml" \
	|| bad "scaffold mounts the home layer and nothing else under /agent besides config.toml" "$(grep '/agent/' "$scf")"
check_instance_compose "new-instance" "$scf" data
[ ! -d "$sc/runtime" ] && ok "scaffold creates no local workspace (deploy owns it on the server)" || bad "scaffold creates no local workspace (deploy owns it on the server)" ""
[ ! -e "$sc/examples/data" ] && ok "scaffold writes nothing under examples/" || bad "scaffold writes nothing under examples/" ""
bash "$SCAFFOLD" --root "$sc" data >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "scaffold refuses to overwrite an existing instance (exit 1)" || bad "scaffold refuses to overwrite an existing instance (exit 1)" "rc=$rc"
before="$(cat "$sc/deploy-repo/hosts/default/host.env")"
bash "$SCAFFOLD" --root "$sc" second >/dev/null 2>&1
[ "$before" = "$(cat "$sc/deploy-repo/hosts/default/host.env")" ] && ok "scaffold never rewrites an existing host.env" || bad "scaffold never rewrites an existing host.env" ""
bash "$SCAFFOLD" --root "$sc" --host hk data >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ -f "$sc/deploy-repo/hosts/hk/instances/data/env" ] && [ -f "$sc/deploy-repo/hosts/hk/host.env" ] \
	&& ok "--host selects the host directory and lays out its host.env" || bad "--host selects the host directory and lays out its host.env" "rc=$rc"
mkdir -p "$sc/elsewhere"; bash "$SCAFFOLD" --root "$sc" --repo "$sc/elsewhere" other >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ -f "$sc/elsewhere/hosts/default/instances/other/env" ] \
	&& ok "--repo overrides the default deploy repo for scaffold" || bad "--repo overrides the default deploy repo for scaffold" "rc=$rc"
mv "$sc/deploy-repo" "$sc/deploy-repo.off"
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$SCAFFOLD" --root "$sc" nowhere 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'deploy-repo' <<<"$out" && ok "scaffold without a deploy repo exits 2 and names deploy-repo" || bad "scaffold without a deploy repo exits 2 and names deploy-repo" "rc=$rc $out"
mv "$sc/deploy-repo.off" "$sc/deploy-repo"
bash "$SCAFFOLD" --root "$sc" --mount kubeconfig gone >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ ! -e "$sc/deploy-repo/hosts/default/instances/gone" ] && ok "scaffold rejects the retired --mount flag (exit 1)" || bad "scaffold rejects the retired --mount flag (exit 1)" "rc=$rc"
bash "$SCAFFOLD" --root "$sc" Bad_Name >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "scaffold rejects an invalid name (exit 1)" || bad "scaffold rejects an invalid name (exit 1)" "rc=$rc"
bash "$SCAFFOLD" --root "$sc" --host Bad_Host x >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "scaffold rejects an invalid host name (exit 1)" || bad "scaffold rejects an invalid host name (exit 1)" "rc=$rc"
bash "$SCAFFOLD" --root "$sc" demo >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "scaffold refuses to target the demo template" || bad "scaffold refuses to target the demo template" "rc=$rc"
```

- [ ] **Step 2: 跑测试确认红**

Run: `bash scripts/test.sh 2>&1 | grep FAIL | head`
Expected: scaffold 组多条 FAIL。

- [ ] **Step 3: 重写 `scaffold.sh`**

```bash
#!/usr/bin/env bash
# Scaffold a new agentbox instance (one trust domain = one compose project = one directory) straight
# into the deploy repo: hosts/<host>/instances/<name>/{docker-compose.yaml,config.toml,env}, cut from
# examples/demo/. When the repo lacks defaults.env or hosts/<host>/host.env they are laid out from the
# templates in .claude/skills/deploy/references/, placeholders only. It never writes secret values.
# The deploy repo comes from --repo, AGENTBOX_DEPLOY_REPO, or <root>/deploy-repo.
# File credentials are not a scaffold concern: the template already mounts ./home:/agent/home:ro.
# Exit codes: 0 ok / 1 usage error or target exists / 2 precondition (deploy repo or template missing)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
NAME=""
HOST="default"
AGENT="claudecode"
REPO="${AGENTBOX_DEPLOY_REPO:-}"
DRY_RUN=0

die()  { echo "Error: $*" >&2; exit 1; }
pre()  { echo "Error: $*" >&2; exit 2; }
warn() { echo "Warning: $*" >&2; }
info() { echo "scaffold: $*" >&2; }

usage() {
	cat <<'USAGE'
Usage: scaffold.sh [options] <name>

Create hosts/<host>/instances/<name>/{docker-compose.yaml,config.toml,env} in the deploy repo from
the examples/demo template. defaults.env and hosts/<host>/host.env are laid out from templates when
missing, placeholders only. Nothing is printed on stdout; progress and the files that still need
values go to stderr.

Arguments:
  <name>                  instance name: lowercase letters, digits, dashes; starts with a letter

Options:
      --host HOST         host directory under hosts/ (default: default)
      --agent TYPE        claudecode (default) or pi; pi selects the -pi image in docker-compose.yaml
      --repo DIR          deploy repository (default: <agentbox root>/deploy-repo, or AGENTBOX_DEPLOY_REPO)
      --root DIR          agentbox root (default: derived from this script's location)
      --dry-run           print the plan on stderr, change nothing
  -h, --help              show this help

Exit codes: 0 success / 1 usage error or the instance already exists / 2 deploy repo or template missing
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--host)    HOST="${2:?missing value}"; shift 2 ;;
		--agent)   AGENT="${2:?missing value}"; shift 2 ;;
		--repo)    REPO="${2:?missing value}"; shift 2 ;;
		--root)    ROOT="$(cd "${2:?missing value}" && pwd)"; shift 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) usage; exit 0 ;;
		--)        shift; break ;;
		-*)        usage >&2; die "unknown option: $1" ;;
		*)         [ -z "${NAME}" ] || { usage >&2; die "only one name is accepted"; }; NAME="$1"; shift ;;
	esac
done
[ $# -eq 0 ] || { [ -z "${NAME}" ] || { usage >&2; die "only one name is accepted"; }; NAME="$1"; }

[ -n "${NAME}" ] || { usage >&2; die "<name> is required"; }
[[ "${NAME}" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "invalid name '${NAME}': use [a-z][a-z0-9-]{0,31}"
[[ "${HOST}" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "invalid host '${HOST}': use [a-z][a-z0-9-]{0,31}"
[ "${NAME}" != demo ] || die "'demo' is the template itself"
case "${AGENT}" in claudecode|pi) ;; *) die "--agent must be claudecode or pi" ;; esac

if [ -z "${REPO}" ]; then
	[ -d "${ROOT}/deploy-repo" ] || pre "no deploy repo: clone or symlink the private deploy repository to ${ROOT}/deploy-repo, or pass --repo (see .claude/skills/deploy/references/deploy-repo.md)"
	REPO="${ROOT}/deploy-repo"
fi
[ -d "${REPO}" ] || pre "deploy repo ${REPO} is not a directory"

TEMPLATE="${ROOT}/examples/demo"
REFS="${ROOT}/.claude/skills/deploy/references"
[ -f "${TEMPLATE}/config.toml" ] && [ -f "${TEMPLATE}/env.example" ] && [ -f "${TEMPLATE}/docker-compose.yaml" ] \
	|| pre "template ${TEMPLATE} is incomplete (docker-compose.yaml + config.toml + env.example required)"
[ -f "${REFS}/host.env.example" ] && [ -f "${REFS}/defaults.env.example" ] \
	|| pre "templates ${REFS}/host.env.example and defaults.env.example are required"

HOST_DIR="${REPO}/hosts/${HOST}"
TARGET="${HOST_DIR}/instances/${NAME}"
[ ! -e "${TARGET}" ] || die "${TARGET} already exists; pick another name or remove it first"
git -C "${REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || warn "${REPO} is not a git repository; deploy cannot trace a deploy back to a commit"

# Files the user has to fill in before deploy plan passes; listed on stderr at the end.
declare -a TO_FILL=()

if [ "${DRY_RUN}" -eq 1 ]; then
	[ -f "${REPO}/defaults.env" ] || echo "plan: create ${REPO}/defaults.env from template" >&2
	[ -f "${HOST_DIR}/host.env" ] || echo "plan: create ${HOST_DIR}/host.env from template" >&2
	echo "plan: create ${TARGET}/docker-compose.yaml (service ${NAME}, agent ${AGENT})" >&2
	echo "plan: create ${TARGET}/config.toml (name=${NAME}, agent.type=${AGENT})" >&2
	echo "plan: create ${TARGET}/env (0600, placeholders)" >&2
	exit 0
fi

install -d -m 0755 "${TARGET}"

if [ ! -f "${REPO}/defaults.env" ]; then
	cp "${REFS}/defaults.env.example" "${REPO}/defaults.env"
	info "created ${REPO}/defaults.env"
	TO_FILL+=("${REPO}/defaults.env")
fi
if [ ! -f "${HOST_DIR}/host.env" ]; then
	cp "${REFS}/host.env.example" "${HOST_DIR}/host.env"
	info "created ${HOST_DIR}/host.env"
	TO_FILL+=("${HOST_DIR}/host.env")
fi

# config.toml: rename the project and set the agent type.
sed -e "s/^name = \"demo\"$/name = \"${NAME}\"/" \
    -e "s/^type = \"claudecode\"$/type = \"${AGENT}\"/" \
    "${TEMPLATE}/config.toml" > "${TARGET}/config.toml"
grep -q "^name = \"${NAME}\"$" "${TARGET}/config.toml" || die "template changed: project name line not found"
grep -q "^type = \"${AGENT}\"$" "${TARGET}/config.toml" || die "template changed: agent type line not found"

# env: the template's env.example, as the real file the user fills in. pi needs its own key.
if [ "${AGENT}" = pi ]; then
	sed -e 's/^# PI_KEY=$/PI_KEY=xxxxxxxxxxxxxxxxxxxxxxxx/' "${TEMPLATE}/env.example" > "${TARGET}/env"
	grep -q '^PI_KEY=' "${TARGET}/env" || die "template changed: PI_KEY line not found"
else
	cp "${TEMPLATE}/env.example" "${TARGET}/env"
fi
chmod 0600 "${TARGET}/env"
TO_FILL+=("${TARGET}/env")

# docker-compose.yaml: rename the service, container and workspace, switch the image tag for pi.
# The indented "# ..." hints in the template are dropped: a scaffolded file lists what it mounts,
# nothing else; the home layer mount comes through as it is.
sed -e "s/^  demo:\$/  ${NAME}:/" \
    -e "s/^    container_name: agentbox-demo\$/    container_name: agentbox-${NAME}/" \
    -e "s|/demo:/workspace\$|/${NAME}:/workspace|" \
    -e '/^      #/d' \
    "${TEMPLATE}/docker-compose.yaml" > "${TARGET}/docker-compose.yaml"
if [ "${AGENT}" = pi ]; then
	sed -i.bak 's|^\(  image: .*:\${AGENTBOX_VERSION}\)$|\1-pi|' "${TARGET}/docker-compose.yaml" && rm -f "${TARGET}/docker-compose.yaml.bak"
	grep -q 'AGENTBOX_VERSION}-pi$' "${TARGET}/docker-compose.yaml" || die "template changed: image line not found"
fi
grep -q "^  ${NAME}:\$" "${TARGET}/docker-compose.yaml" || die "template changed: service line not found"
grep -q "^    container_name: agentbox-${NAME}\$" "${TARGET}/docker-compose.yaml" || die "template changed: container_name line not found"
grep -q "/${NAME}:/workspace\$" "${TARGET}/docker-compose.yaml" || die "template changed: workspace mount not found"
grep -q '^      - ./home:/agent/home:ro$' "${TARGET}/docker-compose.yaml" || die "template changed: home layer mount not found"

info "created ${TARGET}/docker-compose.yaml"
info "created ${TARGET}/config.toml"
info "created ${TARGET}/env (0600)"
info "fill in real values, then commit the deploy repo and run deploy plan ${HOST} ${NAME}:"
for f in "${TO_FILL[@]}"; do echo "  ${f}" >&2; done
```

- [ ] **Step 4: 跑测试确认绿**

Run: `bash scripts/test.sh >/dev/null 2>&1; echo rc=$?; bash scripts/test.sh 2>&1 | grep FAIL`
Expected: rc=0。

- [ ] **Step 5: 改 `SKILL.md`**

- frontmatter `description` 里「generates the instance's docker-compose.yaml, config template, env template and workspace directory」改为「writes the instance's docker-compose.yaml, config.toml and env (placeholders only) into the deploy repo under deploy-repo/, laying out host.env and defaults.env when they are missing」。
- Step 1「Same secrets」一段：`examples/<existing>/config.toml` 的两分支改为只有部署仓库一处，`deploy-repo/hosts/<host>/instances/<existing>/config.toml`（模板实例的说法删掉，因为实例只活在部署仓库；`examples/demo/config.toml` 仍是 `[[projects]]` 注释模板的出处）。工作区子目录一句改为「lives on the server, and the `deploy` skill creates it」。
- Step 2 命令行改为 `.claude/skills/new-instance/scripts/scaffold.sh [--host <host>] [--agent pi] <name>`，条目改为：

```
- The deploy repo is `deploy-repo/` at the agentbox root (`.claude/skills/deploy/references/deploy-repo.md`).
  If it is missing, the script exits 2: tell the user to clone the private deploy repository there
  (or `git init deploy-repo` for a brand-new one) and stop; do not pick a path yourself.
- `--host` names the directory under `hosts/`, default `default`. A missing `hosts/<host>/host.env`
  or `defaults.env` is laid out from the templates with `xxxx` values; an existing one is never touched.
- `<name>` is lowercase letters, digits and dashes. It becomes the service name, the container name
  `agentbox-<name>`, the instance directory and the compose project name (volumes `<name>_state` / `<name>_cache`).
- `--agent pi` sets `agent.type = "pi"`, uncomments `PI_KEY` in `env` and switches the image to the `-pi` tag.
- File credentials are not a scaffold option: the compose already mounts `./home:/agent/home:ro`; lay the
  files out under `home/` like `~` (`docs/CREDENTIALS.md` §2).
- The script refuses to overwrite an existing instance (exit 1) and prints nothing on stdout; stderr ends
  with the list of files that still need values. Run with `--dry-run` first to show the plan.
```

- 删掉「`examples/<name>/` stays a template ...」一段，换成「`examples/` holds the demo template and reference examples only; a scaffolded instance never lands there.」
- Step 3 改为「Read `references/checklist.md` and give the user the steps: fill in the three files the script listed, set `allow_from` to explicit ids, commit the deploy repo, then `deploy plan`. Do not do the human steps for them; values go straight from the user into the files.」
- Final message format：

```
Created in deploy-repo/hosts/<host>/:
- host.env                                 (new, fill in)      # only when created
- instances/<name>/docker-compose.yaml     (image tag ...)
- instances/<name>/config.toml             (agent.type = ...)
- instances/<name>/env                     (0600, fill in)
defaults.env                               (new, fill in)      # only when created

Your steps: (from references/checklist.md, numbered)
```

- [ ] **Step 6: 改 `checklist.md`**

第 1 步替换为：

```
1. **Fill in `host.env` and `defaults.env` if the script created them.** `host.env` is the ssh
   address, key, proxy and remote directory of this host, plus its profile and time zone; behind a
   rule-based proxy write the host as `<ip>.sslip.io` and set the alias to the bare ip
   (`.claude/skills/deploy/references/deploy-repo.md`). `defaults.env` is the image tag from the
   GitHub releases page. Both hold `xxxx` shapes until you edit them, and `deploy plan` refuses to run
   with them.
```

第 2 步开头「Every `${NAME}` in `config.toml` must have a value in `env`」前加「The `env` next to `config.toml` is the real file, already `0600`.」。第 4 步路径 `hosts/<host>/instances/<name>/home/` 前加 `deploy-repo/`。第 5 步前加一句「Commit the deploy repo first: `plan` refuses a dirty one.」。

- [ ] **Step 7: `make check` 并提交**

```bash
make check
git add -A .claude/skills/new-instance scripts/test.sh
git commit -m "new-instance: scaffold straight into deploy-repo/hosts/<host>/instances/<name>"
```

---

### Task 4: `.gitignore`、README、INSTANCES、DECISIONS，本机迁移

**Files:**
- Modify: `.gitignore:1-6`
- Modify: `README.md:7-16,54-56`
- Modify: `docs/INSTANCES.md:33`
- Modify: `docs/DECISIONS.md`（「已否决」表末尾加一行）
- Test: `scripts/test.sh:678`

**Interfaces:**
- Consumes: Task 1-3 的行为。

- [ ] **Step 1: 加断言**

第 678 行后加：

```bash
grep -qxF '/deploy-repo' "$ROOT/.gitignore" && ok "deploy-repo/ is gitignored" || bad "deploy-repo/ is gitignored" ""
grep -q 'deploy-repo' "$ROOT/README.md" && ok "README names deploy-repo/ as the deploy repo location" || bad "README names deploy-repo/ as the deploy repo location" ""
```

Run: `bash scripts/test.sh 2>&1 | grep FAIL` → 两条 FAIL。

- [ ] **Step 2: `.gitignore`**

secrets 段加一行，带注释：

```
# the private deploy repository, cloned or symlinked here; see .claude/skills/deploy/references/deploy-repo.md
/deploy-repo
```

- [ ] **Step 3: README**

「快速开始」现有代码块上方加小标题「本机跑 demo」，其后加第二段：

````
**发布到服务器**（镜像从 GHCR 拉，配置与密钥住独立的私有部署仓库）：

```bash
git clone <私有部署仓库> deploy-repo                              # 或 git init deploy-repo；目录已 gitignore
.claude/skills/new-instance/scripts/scaffold.sh <name>            # 写 deploy-repo/hosts/default/instances/<name>/
# 填 deploy-repo/defaults.env、hosts/default/host.env、instances/<name>/env，提交部署仓库
.claude/skills/deploy/scripts/deploy.sh plan default <name>
.claude/skills/deploy/scripts/deploy.sh deploy default <name>
```

部署仓库的结构见 `.claude/skills/deploy/references/deploy-repo.md`。
````

「开发」段第 55 行改为「四个 Claude Code 技能都在 `.claude/skills/`：`new-instance` 把新实例写进 `deploy-repo/`、`import-instance` 从裸机实例反向导入、`remote-build` 在远端构建镜像、`deploy` 把部署仓库推到主机。部署仓库 clone 或软链到根目录的 `deploy-repo/`（gitignored），三个技能都从那里读。」

- [ ] **Step 4: INSTANCES 第 33 行**

改为「新开信任域用 `.claude/skills/new-instance/SKILL.md`：从 `examples/demo/` 生成实例目录，直接写进部署仓库 `deploy-repo/hosts/<host>/instances/<name>/`，缺 `host.env` / `defaults.env` 时一并从模板生成，不写任何真值。已有裸机 cc-connect 要换成容器的，用 `.claude/skills/import-instance/SKILL.md`：只读读取源主机，按挂载契约写进部署仓库，上线仍走 `deploy`。」

- [ ] **Step 5: DECISIONS**

「已否决」表末尾加：

```
| 2026-09-22 | 部署仓库路径放技能 `.env`（`AGENTBOX_DEPLOY_REPO`）；`new-instance` 产物落 `examples/<name>/` | 改为约定位置：agentbox 根下 gitignored 的 `deploy-repo/`（真 clone 或软链），三个技能同一解析，`--repo` 与环境变量仍可覆盖；`new-instance` 直接写 `deploy-repo/hosts/<host>/instances/<name>/`，`examples/` 只剩模板与样例。原因：第一次使用要手抄仓库骨架、复制改名 `env.example`，且三个技能两层间接读一个路径。名字不用 `deploy/`（像项目自己的目录）也不用点前缀（每天要进去改）。已有布局迁移：`ln -s <原路径> deploy-repo` |
```

- [ ] **Step 6: `make check`**

Run: `make check`
Expected: 全绿。docs-path 断言只查 `scripts|docs|examples|etc|.github|.claude` 前缀，`deploy-repo/...` 不在其中，无需存在。

- [ ] **Step 7: 本机迁移**

读 `.claude/skills/deploy/.env` 里 `AGENTBOX_DEPLOY_REPO` 的值（路径，不是密钥），若目录存在：

```bash
ln -s "<那个路径>" deploy-repo && rm .claude/skills/deploy/.env
.claude/skills/deploy/scripts/deploy.sh plan hk-build 2>&1 | head -5
```

Expected: plan 输出 `repo:` 行指向 `deploy-repo`。

- [ ] **Step 8: Commit**

```bash
git add .gitignore README.md docs/INSTANCES.md docs/DECISIONS.md scripts/test.sh
git commit -m "docs: deploy-repo/ is the deploy repository's place; first-run path in README"
```
