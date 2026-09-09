# 导入技能实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 agentbox 加一个 `import-instance` 技能：只读读取一台裸机上的 cc-connect 实例，把配置、密钥、凭据文件、用户级技能按挂载契约搬进部署仓库 `hosts/<host>/instances/<name>/`，并打出迁移规划与 compose 片段；之后由现有 `deploy` 技能上线。

**Architecture:** 三个文件分三层。`collect.sh` 是只读采集脚本，在源主机上（`ssh host bash -s -- DIR < collect.sh`）或本地（`--local`）执行，产出 tab 分隔的清单，config.toml 全文夹在标记行之间；`render.py` 吃清单做行级改写、工具覆盖对照、生成规划文本，`--out` 时写 `config.toml`、追加 `env`、产出凭据复制清单与 compose 片段；`import-instance.sh` 是驱动，负责 flag、`.env` 三级覆盖、ssh/rsync、目标目录检查、按复制清单 rsync 凭据与技能。密钥值只经 rsync 落盘，不进任何 stdout/stderr。

**Tech Stack:** bash + ssh + rsync；python3（3.11+，`tomllib` 校验产出）；测试是 `scripts/test.sh` 新增断言组，由 `make check`（含 shellcheck）驱动。

**Spec:** `docs/superpowers/specs/2026-09-09-import-instance-design.md`

## Global Constraints

- **语言：脚本一律英文**（注释、帮助、报错、日志、断言名），前缀 `Error:` / `Warning:`，与 `CLAUDE.md` 2026-09-09 的条款和 `gox-code-rules:shell` 0.6.1 一致。文档类（`SKILL.md`、`references/*.md`、`docs/`）中文。
- 每个脚本 `#!/usr/bin/env bash` + `set -euo pipefail`；所有展开加引号并加花括号。python 文件 `#!/usr/bin/env python3`，只用标准库。
- 退出码：`0` 成功 / `1` 用法错误、目标已存在、远端命令失败 / `2` 前置条件不满足（缺 ssh、rsync、python3，源 config.toml 不存在，部署仓库里没有该 host）。帮助文本列出这三条。
- stdout 只放数据：规划表与 compose 片段。进度、警告、诊断走 stderr。无 emoji 无颜色。
- 源主机只读：`collect.sh` 不含任何写操作；`test.sh` 用 grep 锁死。
- 写入范围只有 `hosts/<host>/instances/<name>/`；本机其他目录、agentbox 仓库、源主机一律不写。
- 密钥值（源 `.env` 的值、凭据文件内容、config 里写死的密钥字面值）不出现在规划表、compose 片段、`-v` 诊断、stderr。
- 技能 `.env.example` 不得含真实地址，唯一允许的 IP 字面量是 `127.0.0.1`。真实地址、真实密钥不进 git、文档、对话。
- 每个任务结束前 `make check` 全绿；红了不进下一个任务。
- 部署仓库路径变量与 `deploy` 共用 `AGENTBOX_DEPLOY_REPO`，读取顺序 flag `--repo` > 环境变量 > `.claude/skills/deploy/.env`。不另起变量。
- compose 片段里镜像默认 `ghcr.io/chinayin/agentbox:${AGENTBOX_VERSION}`，可用 `--image` 覆盖。

## 文件结构

| 文件 | 职责 |
|---|---|
| `.claude/skills/import-instance/scripts/import-instance.sh` | 驱动：flag、`.env`、ssh/rsync、目标目录检查、按复制清单拉凭据与技能 |
| `.claude/skills/import-instance/scripts/collect.sh` | 只读采集，在源主机或本地执行，输出清单 |
| `.claude/skills/import-instance/scripts/render.py` | 改写 config、对照 lock、生成规划与片段、写产物 |
| `.claude/skills/import-instance/.env.example` | 源主机连接信息模板 |
| `.claude/skills/import-instance/SKILL.md` | 技能说明与交接清单 |
| `.claude/skills/import-instance/references/mapping.md` | 映射规则（spec §4 的落地版） |
| `scripts/test.sh` | 新增 `import-instance skill` 组；两处 compose 片段共用结构断言；deploy 文件凭据权限断言 |
| `.claude/skills/deploy/scripts/deploy.sh` | 服务器侧对 `instances/<n>/` 下凭据文件 `chmod 600` 并整目录 chown 1000 |
| `.claude/skills/deploy/references/deploy-repo.md` | 服务器布局补上凭据文件与 `claude/` |
| `docs/MULTI_PROJECT.md`、`README.md`、`docs/ROADMAP.md`、`.claude/skills/new-instance/SKILL.md` | 指引与边界 |

---

## Task 1: 驱动骨架：flag、三级覆盖、dry-run

**Files:**
- Create: `.claude/skills/import-instance/scripts/import-instance.sh`
- Create: `.claude/skills/import-instance/.env.example`
- Modify: `scripts/test.sh`（在 `group "deploy skill"` 之后、`group "template hygiene"` 之前插入新组）

**Interfaces:**
- Produces: `import-instance.sh [options] <action> <source-dir>`，action ∈ `plan` | `import`；变量 `AGENTBOX_IMPORT_SOURCE`、`AGENTBOX_IMPORT_KEY`、`AGENTBOX_IMPORT_SOCKS`、`AGENTBOX_IMPORT_HOST_KEY_ALIAS`、`AGENTBOX_DEPLOY_REPO`；函数 `rssh`、`make_rsync_ssh`、`die`、`pre`、`warn`、`step`、`vlog`。后续任务往 `run_collect`、`run_render`、`do_import` 三个函数里填内容。

- [ ] **Step 1: 写失败的断言**

在 `scripts/test.sh` 的 `group "template hygiene"` 那一行之前插入：

```bash
# ---------- import-instance skill ----------
# Reverse of new-instance: reads a running bare-metal cc-connect instance and writes the agentbox
# shape into the deploy repo. Fixture is a fake source instance under mktemp; nothing dials out.
group "import-instance skill"
IM_SRC="$ROOT/.claude/skills/import-instance/scripts"
im="$TMP/im"; mkdir -p "$im/skills/import-instance/scripts" "$im/skills/deploy" "$im/repo/hosts/h1/instances" "$im/other/hosts/h2/instances"
cp "$IM_SRC"/* "$im/skills/import-instance/scripts/"
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

```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh 2>&1 | grep -A20 'import-instance skill' | head -30`
Expected: 全部 `[FAIL]`（脚本不存在）。

- [ ] **Step 3: 写 `.env.example`**

```bash
# Source host for the import-instance skill: the bare-metal machine that runs the cc-connect
# instance to import. Copy to .env (gitignored); flags and environment variables override.
# Behind a rule-based proxy (Clash) write the host as <ip>.sslip.io and set the alias to the bare ip.
# The deploy repo path is not here: it comes from .claude/skills/deploy/.env (AGENTBOX_DEPLOY_REPO).
AGENTBOX_IMPORT_SOURCE=root@xxx.xxx.xxx.xxx.sslip.io
AGENTBOX_IMPORT_KEY=~/.ssh/xxxx.pem
# AGENTBOX_IMPORT_SOCKS=127.0.0.1:7890
# AGENTBOX_IMPORT_HOST_KEY_ALIAS=xxx.xxx.xxx.xxx
```

- [ ] **Step 4: 写驱动骨架**

`.claude/skills/import-instance/scripts/import-instance.sh`：

```bash
#!/usr/bin/env bash
# Import a bare-metal cc-connect instance into the deploy repo as an agentbox instance. The source
# host is read only (collect.sh), the rendering is local (render.py), and the only place written is
# hosts/<host>/instances/<name>/ in the deploy repo. Secrets travel by rsync straight into that
# directory and never through stdout, stderr or this script's variables.
# Source connection comes from, in order of precedence: flags, environment variables, the skill's
# .env (../.env next to this script, gitignored; template in ../.env.example). The deploy repo path
# comes from --repo, AGENTBOX_DEPLOY_REPO, or the deploy skill's .env (shared variable, one truth).
# Exit codes: 0 ok / 1 usage error, target exists or remote failure / 2 precondition not met

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "${SKILL_DIR}/../../.." && pwd)"
DEPLOY_SKILL_DIR="${SKILL_DIR}/../deploy"

# Fill only what is still unset, so the environment and flags always win. A leading ~/ expands.
load_env_file() {
	local file="$1"; shift
	[ -f "${file}" ] || return 0
	local line name val
	while IFS= read -r line || [ -n "${line}" ]; do
		case "${line}" in ''|\#*) continue ;; esac
		name="${line%%=*}"; val="${line#*=}"
		case " $* " in *" ${name} "*) ;; *) continue ;; esac
		# shellcheck disable=SC2088  # matching a literal leading ~/ from the file is the point here
		case "${val}" in "~/"*) val="${HOME}/${val#\~/}" ;; esac
		[ -n "${!name:-}" ] || export "${name}=${val}"
	done < "${file}"
}
load_env_file "${SKILL_DIR}/.env" AGENTBOX_IMPORT_SOURCE AGENTBOX_IMPORT_KEY AGENTBOX_IMPORT_SOCKS AGENTBOX_IMPORT_HOST_KEY_ALIAS
load_env_file "${DEPLOY_SKILL_DIR}/.env" AGENTBOX_DEPLOY_REPO

SOURCE="${AGENTBOX_IMPORT_SOURCE:-}"
KEY="${AGENTBOX_IMPORT_KEY:-}"
SOCKS="${AGENTBOX_IMPORT_SOCKS:-}"
HOST_KEY_ALIAS="${AGENTBOX_IMPORT_HOST_KEY_ALIAS:-}"
REPO="${AGENTBOX_DEPLOY_REPO:-}"
IMAGE="ghcr.io/chinayin/agentbox"
LOCAL=0
ACTION=""
SRC_DIR=""
HOST=""
NAME=""
HOME_DIR=""
VERBOSE=0
DRY_RUN=0
declare -a SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new)

die()  { echo "Error: $*" >&2; exit 1; }
pre()  { echo "Error: $*" >&2; exit 2; }
warn() { echo "Warning: $*" >&2; }
step() { echo "==> $*" >&2; }
vlog() { [ "${VERBOSE}" -eq 1 ] && echo "verbose: $*" >&2 || true; }

usage() {
	cat <<'USAGE'
Usage: import-instance.sh [options] <action> <source-dir>

Actions:
  plan     read the source instance and print the migration plan; writes nothing
  import   plan, then write hosts/<host>/instances/<name>/ in the deploy repo and print the
           compose snippet; requires --host and --name

Arguments:
  <source-dir>   the instance directory holding config.toml and .env (on the source host, or a
                 local directory with --local)

Options:
      --source USER@HOST   source host (or AGENTBOX_IMPORT_SOURCE)
      --key PATH           SSH private key for the source host (or AGENTBOX_IMPORT_KEY)
      --socks HOST:PORT    SOCKS5 proxy for the source host (or AGENTBOX_IMPORT_SOCKS)
      --host-key-alias H   known_hosts alias, pairs with a <ip>.sslip.io host form
      --local              <source-dir> is a local directory; no connection is made
      --home DIR           owner's home directory on the source (default: derived from the owner
                           of config.toml); needed with --local
      --repo DIR           deploy repository (or AGENTBOX_DEPLOY_REPO, or the deploy skill .env)
      --host HOST          host directory in the deploy repo (hosts/<host> must already exist)
      --name NAME          instance name: [a-z][a-z0-9-]{0,31}
      --image REPO         image repository for the snippet (default ghcr.io/chinayin/agentbox)
      --dry-run            print what would run and what would be written; no connection, no files
  -v, --verbose            extra diagnostics on stderr (never a value from the source .env)
  -h, --help               show this help

Exit codes: 0 success / 1 usage error, target exists or remote failure / 2 precondition not met
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--source)          SOURCE="${2:?missing value}"; shift 2 ;;
		--key)             KEY="${2:?missing value}"; shift 2 ;;
		--socks)           SOCKS="${2:?missing value}"; shift 2 ;;
		--host-key-alias)  HOST_KEY_ALIAS="${2:?missing value}"; shift 2 ;;
		--local)           LOCAL=1; shift ;;
		--home)            HOME_DIR="${2:?missing value}"; shift 2 ;;
		--repo)            REPO="${2:?missing value}"; shift 2 ;;
		--host)            HOST="${2:?missing value}"; shift 2 ;;
		--name)            NAME="${2:?missing value}"; shift 2 ;;
		--image)           IMAGE="${2:?missing value}"; shift 2 ;;
		--dry-run)         DRY_RUN=1; shift ;;
		-v|--verbose)      VERBOSE=1; shift ;;
		-h|--help)         usage; exit 0 ;;
		--)                shift; break ;;
		-*)                usage >&2; die "unknown option: $1" ;;
		plan|import)       [ -z "${ACTION}" ] || { usage >&2; die "only one action is accepted"; }; ACTION="$1"; shift ;;
		*)                 [ -z "${SRC_DIR}" ] || { usage >&2; die "only one source directory is accepted"; }; SRC_DIR="$1"; shift ;;
	esac
done
[ $# -eq 0 ] || { [ -z "${SRC_DIR}" ] || { usage >&2; die "only one source directory is accepted"; }; SRC_DIR="$1"; }

[ -n "${ACTION}" ] || { usage >&2; die "an action is required: plan or import"; }
[ -n "${SRC_DIR}" ] || { usage >&2; die "<source-dir> is required"; }
if [ "${LOCAL}" -eq 0 ]; then
	[ -n "${SOURCE}" ] || { usage >&2; die "--source, AGENTBOX_IMPORT_SOURCE, or the skill .env is required (or pass --local)"; }
	[ -n "${KEY}" ] && SSH_OPTS+=(-i "${KEY}")
	# BSD nc SOCKS5 syntax; ssh substitutes %h %p.
	[ -n "${SOCKS}" ] && SSH_OPTS+=(-o "ProxyCommand=nc -X 5 -x ${SOCKS} %h %p")
	[ -n "${HOST_KEY_ALIAS}" ] && SSH_OPTS+=(-o "HostKeyAlias=${HOST_KEY_ALIAS}")
fi
if [ "${ACTION}" = import ]; then
	[ -n "${HOST}" ] || { usage >&2; die "import requires --host"; }
	[ -n "${NAME}" ] || { usage >&2; die "import requires --name"; }
	[[ "${NAME}" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "invalid name '${NAME}': use [a-z][a-z0-9-]{0,31}"
	[ -n "${REPO}" ] || { usage >&2; die "--repo, AGENTBOX_DEPLOY_REPO, or ${DEPLOY_SKILL_DIR}/.env is required for import"; }
	HOST_DIR="${REPO}/hosts/${HOST}"
	[ -f "${HOST_DIR}/host.env" ] || pre "host '${HOST}' not found in ${REPO} (expected ${HOST_DIR}/host.env; see .claude/skills/deploy/references/deploy-repo.md)"
	TARGET="${HOST_DIR}/instances/${NAME}"
fi
for t in ssh rsync python3; do
	[ "${LOCAL}" -eq 1 ] && [ "${t}" != python3 ] && continue
	command -v "${t}" >/dev/null 2>&1 || pre "${t} is required"
done

# Every command on the source goes through here; ssh's exit code passes through.
rssh() {
	vlog "ssh ${SOURCE}: $*"
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "plan: ssh ${SOURCE} -- $*" >&2
		return 0
	fi
	ssh "${SSH_OPTS[@]}" "${SOURCE}" "$@"
}

# rsync -e takes one string; options with spaces (ProxyCommand) need a wrapper script.
make_rsync_ssh() {
	local wrapper="$1" opt
	{
		echo '#!/usr/bin/env bash'
		printf 'exec ssh'
		for opt in "${SSH_OPTS[@]}"; do printf ' %q' "${opt}"; done
		echo ' "$@"'
	} > "${wrapper}"
	chmod 0700 "${wrapper}"
}

TMP="$(mktemp -d)"
chmod 0700 "${TMP}"
# shellcheck disable=SC2064  # expand TMP now, on purpose
trap "rm -rf '${TMP}'" EXIT

run_collect() { :; }   # Task 2
run_render()  { :; }   # Task 3
do_import()   { :; }   # Task 4

case "${ACTION}" in
	plan)
		if [ "${DRY_RUN}" -eq 1 ]; then
			if [ "${LOCAL}" -eq 1 ]; then echo "plan: bash collect.sh${HOME_DIR:+ --home ${HOME_DIR}} ${SRC_DIR} (local)" >&2
			else echo "plan: ssh ${SOURCE} -- bash -s -- ${SRC_DIR} < collect.sh" >&2; fi
			echo "plan: render the migration plan to stdout" >&2
			exit 0
		fi
		run_collect; run_render ;;
	import)
		if [ "${DRY_RUN}" -eq 1 ]; then
			if [ "${LOCAL}" -eq 1 ]; then echo "plan: bash collect.sh${HOME_DIR:+ --home ${HOME_DIR}} ${SRC_DIR} (local)" >&2
			else echo "plan: ssh ${SOURCE} -- bash -s -- ${SRC_DIR} < collect.sh" >&2; fi
			echo "plan: write ${TARGET}/{config.toml,env} plus credential files and claude/ (0600 for credentials)" >&2
			echo "plan: print the compose snippet for service '${NAME}' with image ${IMAGE}" >&2
			exit 0
		fi
		run_collect; do_import ;;
esac
```

- [ ] **Step 5: 跑测试确认通过**

Run: `make check 2>&1 | grep -E 'import-instance|result:'`
Expected: 本组全部 `[PASS]`，`result: ... FAIL=0`。shellcheck 也过（`make check` 含 lint；`--`/`plan|import` 分支若被报 SC2221/SC2222 则调整 case 顺序）。

- [ ] **Step 6: 提交**

```bash
git add .claude/skills/import-instance/scripts/import-instance.sh .claude/skills/import-instance/.env.example scripts/test.sh
git commit -m "feat(import-instance): driver skeleton with source/repo overrides and dry-run"
```

---

## Task 2: 只读采集脚本 `collect.sh`

**Files:**
- Create: `.claude/skills/import-instance/scripts/collect.sh`
- Modify: `.claude/skills/import-instance/scripts/import-instance.sh`（填 `run_collect`）
- Modify: `scripts/test.sh`（本组追加 fixture 与断言）

**Interfaces:**
- Produces: `collect.sh [--home DIR] <instance-dir>`，stdout 每行一条 tab 分隔记录，首字段是类型：`owner`、`uid`、`home`、`work_dir`、`unit_file`、`unit <Key> <value>`、`env_key <NAME>`、`kube_file <basename> <bytes>`、`ssh_key <basename>`、`ssh_pub <basename>`、`user_skill <name> <docker-hits|->`、`skill_lock <path>`、`ws_skill <relpath> <docker-hits|->`、`git_remote <url>`、`tool <name> <path> <version>`；config.toml 全文夹在 `__AGENTBOX_CONFIG_BEGIN__` 与 `__AGENTBOX_CONFIG_END__` 两行之间。
- 驱动把清单写到 `${TMP}/inventory`；`run_collect` 之后 `INVENTORY="${TMP}/inventory"` 可用。

- [ ] **Step 1: 写 fixture 与失败的断言**

在本组已有断言之后追加：

```bash
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
hits="$(grep -vE '^[[:space:]]*#' "$IM_SRC/collect.sh" | grep -E '(^|[^0-9&])>' | grep -vE '2>/dev/null|>&2|2>&1|</dev/null' || true)"
[ -z "$hits" ] && ok "collect.sh has no redirection that could write a file" || bad "collect.sh has no redirection that could write a file" "$hits"
hits="$(grep -vE '^[[:space:]]*#' "$IM_SRC/collect.sh" | grep -nwE 'tee|rm|chmod|chown|systemctl|mkdir|install|mv|cp|truncate|sed -i' || true)"
[ -z "$hits" ] && ok "collect.sh calls no command that writes" || bad "collect.sh calls no command that writes" "$hits"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh 2>&1 | grep -E 'collect' `
Expected: 全部 `[FAIL]`。

- [ ] **Step 3: 写 `collect.sh`**

```bash
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
Usage: collect.sh [--home DIR] <instance-dir>

Print a read-only inventory of the cc-connect instance in <instance-dir> (the directory holding
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
[ -n "${DIR}" ] || { usage >&2; echo "Error: <instance-dir> is required" >&2; exit 1; }
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
for d in "${HOME_DIR}"/.claude/skills/*/; do
	[ -f "${d}/SKILL.md" ] || continue
	hits="$(docker_hits "${d}")"
	rec user_skill "$(basename "${d}")" "${hits:--}"
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
for t in node npm go python3 pip3 uv kubectl helm helmfile kustomize aws aliyun gh glab git jq yq rg fd mise claude cc-connect pi codex cloudflared docker; do
	p="$(command -v "${t}" 2>/dev/null)" || continue
	case "${t}" in
		go)      v="$("${tmo[@]+"${tmo[@]}"}" go version 2>&1 | head -1)" ;;
		kubectl) v="$("${tmo[@]+"${tmo[@]}"}" kubectl version --client 2>/dev/null | head -1)" ;;
		helm)    v="$("${tmo[@]+"${tmo[@]}"}" helm version --short 2>&1 | head -1)" ;;
		*)       v="$("${tmo[@]+"${tmo[@]}"}" "${t}" --version 2>&1 | head -1)" ;;
	esac || v="?"
	rec tool "${t}" "${p}" "${v:0:80}"
done

# The config itself: placeholders and S2 literals by contract. Markers let the renderer cut it out.
rec __AGENTBOX_CONFIG_BEGIN__
cat "${DIR}/config.toml"
rec __AGENTBOX_CONFIG_END__
```

- [ ] **Step 4: 填驱动的 `run_collect`**

替换 Task 1 里的占位 `run_collect() { :; }`：

```bash
INVENTORY="${TMP}/inventory"
run_collect() {
	if [ "${LOCAL}" -eq 1 ]; then
		step "collecting from local directory ${SRC_DIR}"
		[ -n "${HOME_DIR}" ] || warn "--home not given; the owner's home will be derived, which usually fails off the source host"
		bash "${SKILL_DIR}/scripts/collect.sh" ${HOME_DIR:+--home "${HOME_DIR}"} "${SRC_DIR}" > "${INVENTORY}"
	else
		step "collecting from ${SOURCE}:${SRC_DIR} (read-only)"
		vlog "ssh ${SOURCE}: bash -s -- ${SRC_DIR} < collect.sh"
		ssh "${SSH_OPTS[@]}" "${SOURCE}" "bash -s -- ${HOME_DIR:+--home '${HOME_DIR}' }'${SRC_DIR}'" \
			< "${SKILL_DIR}/scripts/collect.sh" > "${INVENTORY}"
	fi
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `make check 2>&1 | grep -E 'collect|result:'`
Expected: 全部 `[PASS]`，`FAIL=0`。若 shellcheck 报 `${HOME_DIR:+--home "${HOME_DIR}"}` 未加引号（SC2086），改成数组：`declare -a hargs=(); [ -n "${HOME_DIR}" ] && hargs=(--home "${HOME_DIR}")`，再 `"${hargs[@]+"${hargs[@]}"}"`。

- [ ] **Step 6: 提交**

```bash
git add .claude/skills/import-instance/scripts/collect.sh .claude/skills/import-instance/scripts/import-instance.sh scripts/test.sh
git commit -m "feat(import-instance): read-only source inventory (collect.sh)"
```

---

## Task 3: `render.py` 规划模式：行级改写、工具对照、规划文本

**Files:**
- Create: `.claude/skills/import-instance/scripts/render.py`
- Modify: `.claude/skills/import-instance/scripts/import-instance.sh`（填 `run_render`）
- Modify: `scripts/test.sh`

**Interfaces:**
- Produces: `render.py --inventory FILE --lock FILE [--lock FILE ...] --name NAME [--host HOST] [--image REPO] [--out DIR --copy-list FILE]`。无 `--out` 时只打规划到 stdout。`--out` 行为在 Task 4。
- 规划文本固定段头：`== artifacts`、`== config rewrites`、`== file credentials`、`== skills`、`== tools`、`== red items`。

- [ ] **Step 1: 写失败的断言**

```bash
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
tinv="$im/tools.inv"; { echo "$inv" | grep -v '^tool	'; printf 'tool\tkubectl\t/usr/bin/kubectl\tClient Version: v1.36.4\ntool\tfoo\t/usr/bin/foo\tfoo 9.9\ntool\tdocker\t/usr/bin/docker\tDocker version 29.7.2\n'; } > "$tinv"
tplan="$(python3 "$IM_SRC/render.py" --inventory "$tinv" --lock "$ROOT/mise.lock" --lock "$ROOT/mise.claude.lock" --name t 2>&1)"
grep -qE '^ *kubectl .*covered' <<<"$tplan" && grep -qE '^ *foo .*not in lock' <<<"$tplan" && sed -n '/^== red items/,$p' <<<"$tplan" | grep -q 'foo' \
	&& ok "tool coverage marks covered and not-in-lock tools, the latter red" || bad "tool coverage marks covered and not-in-lock tools, the latter red" "$tplan"
sed -n '/^== red items/,$p' <<<"$tplan" | grep -q 'docker' && ok "docker on the source is always a red item" || bad "docker on the source is always a red item" "$tplan"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh 2>&1 | grep -E '\[FAIL\].*(plan|tool|red)'`
Expected: 本步新增断言全部 `[FAIL]`。

- [ ] **Step 3: 写 `render.py`（规划模式）**

```python
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
```

- [ ] **Step 4: 填驱动的 `run_render`**

```bash
LOCKS=(--lock "${ROOT}/mise.lock" --lock "${ROOT}/mise.claude.lock" --lock "${ROOT}/mise.pi.lock")
run_render() {
	step "rendering the migration plan"
	python3 "${SKILL_DIR}/scripts/render.py" --inventory "${INVENTORY}" "${LOCKS[@]}" --name "${NAME:-instance}" ${HOST:+--host "${HOST}"} --image "${IMAGE}"
}
```

shellcheck 会对 `${HOST:+--host "${HOST}"}` 报 SC2086，改成数组 `hargs`，与 Task 2 Step 5 同法。

- [ ] **Step 5: 跑测试确认通过**

Run: `make check 2>&1 | grep -E '\[FAIL\]|result:'`
Expected: `FAIL=0`。

- [ ] **Step 6: 提交**

```bash
git add .claude/skills/import-instance/scripts/render.py .claude/skills/import-instance/scripts/import-instance.sh scripts/test.sh
git commit -m "feat(import-instance): render the migration plan (config rewrite, tool coverage, red items)"
```

---

## Task 4: 导入模式：写产物、拉凭据与技能、compose 片段

**Files:**
- Modify: `.claude/skills/import-instance/scripts/render.py`（实现 `write_out`、`snippet`）
- Modify: `.claude/skills/import-instance/scripts/import-instance.sh`（实现 `do_import`）
- Modify: `scripts/test.sh`

**Interfaces:**
- Produces: `--copy-list FILE` 每行 `kind\tsrc\tdst`，kind ∈ `cred`（单文件，落地 0600）、`dir`（目录，递归）、`file`（普通文件）。`dst` 相对目标实例目录。
- 片段：`  # --- add under services: ---` 开头，`  # --- add under volumes: ---` 分隔，末尾 `  # --- add once at top level ---` 的 `networks` 块。

- [ ] **Step 1: 写失败的断言**

```bash
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
diff <(grep -vE '^(work_dir|ANTHROPIC_MODEL|GATEWAY_ADMIN_TOKEN|KUBECONFIG|HTTPS_PROXY|NO_PROXY|GIT_SSH_COMMAND) ' "$src/config.toml") <(grep -vE '^(work_dir|ANTHROPIC_MODEL|GATEWAY_ADMIN_TOKEN|KUBECONFIG|HTTPS_PROXY|NO_PROXY|GIT_SSH_COMMAND) ' "$tgt/config.toml") >/dev/null \
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
```

注意：`deploy plan` 在非 git 仓库上只 warn 不失败（fixture 目录不是 git 仓库），且它会读 `hosts/h1/host.env`（Task 1 已建）。

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh 2>&1 | grep -E '\[FAIL\].*import'`
Expected: 本步断言 `[FAIL]`，且 Task 3 的断言仍 PASS。

- [ ] **Step 3: 实现 `write_out` 与 `snippet`**

替换 Task 3 里的两个占位函数：

```python
def write_out(a, recs, new_config, ctx):
    out = a.out
    if not a.copy_list:
        die("--copy-list is required with --out")
    env_path = os.path.join(out, "env")
    if not os.path.isfile(env_path):
        die(f"{env_path} must exist before rendering (copied from the source .env)", 2)
    home = field(recs, "home")
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
    for src, dst in ctx["kube"]:
        rows.append(("cred", src, dst))
    ssh_keys = [r[0] for r in fields(recs, "ssh_key")]
    if ssh_keys:
        rows.append(("cred", f"{home}/.ssh/{ssh_keys[0]}", "ssh_key"))
    for s in fields(recs, "user_skill"):
        rows.append(("dir", f"{home}/.claude/skills/{s[0]}/", f"claude/.claude/skills/{s[0]}/"))
    lock_path = field(recs, "skill_lock")
    if lock_path:
        rows.append(("file", lock_path, "claude/.skill-lock.json"))
    with open(a.copy_list, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write("\t".join(r) + "\n")


def snippet(a, recs, ctx):
    n = a.name
    L = ["", "  # --- add under services: ---", f"  {n}:", f"    image: {a.image}:${{AGENTBOX_VERSION}}",
         f"    container_name: agentbox-{n}", "    restart: unless-stopped", "    init: true",
         "    stop_grace_period: 30s", "    security_opt: [no-new-privileges:true]", "    cap_drop: [ALL]",
         "    deploy: {resources: {limits: {pids: 512}}}", "    networks: [agentbox]",
         "    env_file:", f"      - ./instances/{n}/env", "    volumes:",
         f"      - ./instances/{n}/config.toml:/agent/config.toml:ro", f"      - ./workspaces/{n}:/workspace",
         f"      - {n}-state:/state", f"      - {n}-cache:/cache"]
    for dst, mount in ctx["mounts"]:
        L.append(f"      - ./instances/{n}/{dst}:{mount}:ro")
    if fields(recs, "user_skill"):
        L.append(f"      - ./instances/{n}/claude:/etc/claude-code:ro")
    L += ["", "  # --- add under volumes: ---", f"  {n}-state:", f"  {n}-cache:", "",
          "  # --- add once at top level (deploy creates the network on the host) ---",
          "networks:", "  agentbox:", "    external: true", ""]
    return "\n".join(L)
```

- [ ] **Step 4: 实现驱动的 `do_import`**

```bash
# Fetch one path from the source into the target. kind: cred (file, 0600) / file / dir.
fetch() {
	local kind="$1" src="$2" dst="$3"
	vlog "fetch ${kind} ${src} -> ${dst}"
	install -d -m 0700 "$(dirname "${dst}")"
	if [ "${LOCAL}" -eq 1 ]; then
		if [ "${kind}" = dir ]; then cp -R "${src%/}/." "${dst}"; else cp "${src}" "${dst}"; fi
	else
		rsync -a -e "${TMP}/ssh" "${SOURCE}:${src}" "${dst}"
	fi
	[ "${kind}" = cred ] && chmod 600 "${dst}"
	return 0
}

do_import() {
	[ ! -e "${TARGET}" ] || die "${TARGET} already exists; remove it or pick another name"
	[ "${LOCAL}" -eq 1 ] || make_rsync_ssh "${TMP}/ssh"
	step "writing ${TARGET}"
	install -d -m 0700 "${TARGET}"
	# .env first: rendering appends the lifted literals to it. It goes straight to disk.
	fetch cred "${SRC_DIR}/.env" "${TARGET}/env"
	python3 "${SKILL_DIR}/scripts/render.py" --inventory "${INVENTORY}" "${LOCKS[@]}" \
		--name "${NAME}" --host "${HOST}" --image "${IMAGE}" --out "${TARGET}" --copy-list "${TMP}/copies"
	local kind src dst n=0
	while IFS=$'\t' read -r kind src dst; do
		[ -n "${kind}" ] || continue
		fetch "${kind}" "${src}" "${TARGET}/${dst}"
		n=$((n + 1))
	done < "${TMP}/copies"
	step "imported ${NAME}: config.toml, env and ${n} credential/skill entries under ${TARGET}"
	echo "next: review env (chat app, proxy, kubeconfig set), paste the snippet into ${HOST_DIR}/docker-compose.yaml, commit, then: deploy.sh plan ${HOST} ${NAME}" >&2
}
```

render 失败时（config 不解析）`set -e` 让脚本退出，但 `TARGET` 已建且含 `env`：在 `do_import` 开头加 `trap 'rm -rf "${TARGET}"' ERR` 并在成功末尾 `trap - ERR`，保证失败不留半成品。`set -e` 下 `trap ERR` 对函数内失败命令生效。

- [ ] **Step 5: 跑测试确认通过**

Run: `make check 2>&1 | grep -E '\[FAIL\]|result:'`
Expected: `FAIL=0`。macOS 上 `stat -f %Lp` 先行、Linux 上 `stat -c %a` 兜底，两个平台都能跑。

- [ ] **Step 6: 提交**

```bash
git add .claude/skills/import-instance/scripts/render.py .claude/skills/import-instance/scripts/import-instance.sh scripts/test.sh
git commit -m "feat(import-instance): import writes the instance directory, fetches credentials and skills, prints the snippet"
```

---

## Task 5: `deploy` 服务器侧对文件型凭据设权限

**Files:**
- Modify: `.claude/skills/deploy/scripts/deploy.sh`（`sync_host` 的 dry-run 行、`prepare_workspaces`）
- Modify: `.claude/skills/deploy/references/deploy-repo.md`（服务器布局）
- Modify: `scripts/test.sh`（`deploy skill` 组追加断言）

**Interfaces:**
- 服务器上 `instances/<n>/` 整目录 `chown -R 1000:1000`；目录内除 `config.toml` 与 `claude/` 子树外所有文件 `chmod 600`。

- [ ] **Step 1: 写失败的断言**

在 `deploy skill` 组 `"dry-run shows rsync, compose and the 0600 step"` 断言之后追加：

```bash
grep -q 'chown -R 1000:1000' <<<"$out" && grep -q 'config.toml and claude/ excepted' <<<"$out" \
	&& ok "dry-run shows file credentials tightened and the instance directory chowned" || bad "dry-run shows file credentials tightened and the instance directory chowned" "$out"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/test.sh 2>&1 | grep 'chowned'`
Expected: `[FAIL]`。

- [ ] **Step 3: 改 `deploy.sh`**

`sync_host` 里的 dry-run 行改为：

```bash
		echo "plan: chmod 600 every file under ${DEPLOY_DIR}/instances/*/ (config.toml and claude/ excepted) and chown -R 1000:1000 each instance directory" >&2
```

非 dry-run 分支里把 `rssh "chmod 600 '${DEPLOY_DIR}'/instances/*/env"` 改为：

```bash
		# Every file credential (env, kubeconfig-*, ssh_key) is 0600; config.toml stays readable
		# because the container reads it through the bind mount, and claude/ is a read-only code
		# tree the agent must be able to list. docs/TOOLS.md section 3 explains the split.
		rssh "find '${DEPLOY_DIR}'/instances -mindepth 2 -type f ! -name config.toml ! -path '*/claude/*' -exec chmod 600 {} +"
```

`prepare_workspaces` 里把 `rssh "chown 1000:1000 '${DEPLOY_DIR}/instances/${n}/env'"` 改为：

```bash
		rssh "chown -R 1000:1000 '${DEPLOY_DIR}/instances/${n}'"
```

- [ ] **Step 4: 改 `deploy-repo.md` 服务器布局**

「Server layout」代码块改为：

```
/data/agentbox/                       DEPLOY_DIR
  docker-compose.yaml
  .env                                 written by deploy; compose variables only, no ssh info
  instances/<name>/config.toml         0644, owned by UID 1000
  instances/<name>/env                 0600, owned by UID 1000
  instances/<name>/kubeconfig-*        0600, owned by UID 1000 (file credentials, one file each)
  instances/<name>/ssh_key             0600, owned by UID 1000
  instances/<name>/claude/             read-only managed layer for /etc/claude-code (skills, lock)
  workspaces/<name>/                   created and chowned to UID 1000 by deploy
```

并在「Why `config.toml` and `env` do not share a mode」一节末尾加一段：

> File credentials (`kubeconfig-*`, `ssh_key`) follow `env`: 0600 and owned by UID 1000, because the container reads them through a bind mount as that UID and nothing else on the host should. `claude/` is code, not credentials, and keeps the modes it arrived with. `deploy` applies all of this on every run, so an instance written by `import-instance` needs no manual chmod on the server.

- [ ] **Step 5: 跑测试确认通过**

Run: `make check 2>&1 | grep -E '\[FAIL\]|result:'`
Expected: `FAIL=0`。

- [ ] **Step 6: 提交**

```bash
git add .claude/skills/deploy/scripts/deploy.sh .claude/skills/deploy/references/deploy-repo.md scripts/test.sh
git commit -m "fix(deploy): tighten every file credential and chown the instance directory on the server"
```

---

## Task 6: 两处 compose 片段共用结构断言

**Files:**
- Modify: `scripts/test.sh`（在 `group "new-instance scaffold"` 之前定义 helper；两组各调用一次）

- [ ] **Step 1: 写 helper 与两条断言**

在 `group "new-instance scaffold"` 那一行之前加：

```bash
# One structural check for every compose snippet the repo prints (new-instance and import-instance):
# service line, env_file, the config mount, both volumes in the service and in the volumes block.
# $1 label, $2 snippet text, $3 service name, $4 instance path prefix (./examples or ./instances)
check_snippet() {
	local label="$1" s="$2" n="$3" p="$4"
	grep -q "^  ${n}:\$" <<<"$s" && grep -q '^    env_file:' <<<"$s" \
		&& grep -q "^      - ${p}/${n}/env\$" <<<"$s" \
		&& grep -q "^      - ${p}/${n}/config.toml:/agent/config.toml:ro\$" <<<"$s" \
		&& grep -q "^      - ${n}-state:/state\$" <<<"$s" && grep -q "^      - ${n}-cache:/cache\$" <<<"$s" \
		&& grep -q "^  ${n}-state:\$" <<<"$s" && grep -q "^  ${n}-cache:\$" <<<"$s" \
		&& ok "${label} snippet has the shared compose structure" || bad "${label} snippet has the shared compose structure" "$s"
}
```

在 new-instance 组 `"snippet names the service, the pi image, ..."` 断言之后加：

```bash
check_snippet "new-instance" "$snippet" data ./examples
```

在 import-instance 组 `"snippet mounts config, workspace, ..."` 断言之后加：

```bash
check_snippet "import-instance" "$snip" srcops ./instances
```

- [ ] **Step 2: 跑测试确认通过**

Run: `make check 2>&1 | grep -E 'shared compose structure|result:'`
Expected: 两条 `[PASS]`，`FAIL=0`。若 import 片段的 `env_file` 行格式与 helper 不符，改 `render.py` 的 `snippet` 而不是放宽 helper。

- [ ] **Step 3: 提交**

```bash
git add scripts/test.sh
git commit -m "test: one structural check for both compose snippets"
```

---

## Task 7: SKILL.md、映射参考、文档与边界

**Files:**
- Create: `.claude/skills/import-instance/SKILL.md`
- Create: `.claude/skills/import-instance/references/mapping.md`
- Modify: `docs/MULTI_PROJECT.md`（§1 末段）
- Modify: `README.md`（「开发」一节）
- Modify: `docs/ROADMAP.md`（P1 表第 4、5 行；新增一行）
- Modify: `.claude/skills/new-instance/SKILL.md`（开头加边界）

- [ ] **Step 1: 写 `SKILL.md`**

```markdown
---
name: import-instance
description: Import a cc-connect instance that runs directly on a server (npm-installed cc-connect under systemd, config.toml and .env in a directory) into this repository's deploy shape. Use it whenever the user wants to migrate, move, containerize or "搬迁 / 迁移 / 导入" an existing agent from a physical or virtual machine into agentbox, or asks what a bare-metal instance would look like as mounts. It reads the source host read-only, writes hosts/<host>/instances/<name>/ in the deploy repo with the real values, and prints the migration plan and the compose snippet. It never deploys; that is the deploy skill's job.
---

# Import instance

`new-instance` 从模板造空壳，本技能从现状反推：读一台已经在跑的裸机实例，按挂载契约（`README.md` 的表）把它改写成部署仓库里的一个实例目录。源主机全程只读，源实例不停。

## 配置

源主机连接信息在 `.claude/skills/import-instance/.env`（gitignored，模板 `.env.example`），形状与 `remote-build` 相同；Clash 之类规则代理下用 `<ip>.sslip.io` 加 host-key alias。部署仓库路径复用 `deploy` 技能的 `.env`（`AGENTBOX_DEPLOY_REPO`），不另配。两个 `.env` 缺任何一个，都指向对应的 `.env.example` 然后停下，不在 chat 里问地址或路径。

## 动作

```bash
.claude/skills/import-instance/scripts/import-instance.sh plan   <source-dir>
.claude/skills/import-instance/scripts/import-instance.sh import <source-dir> --host <host> --name <name>
```

- `<source-dir>` 是源主机上含 `config.toml` 与 `.env` 的目录（systemd 单元里的 `WorkingDirectory` 或 `EnvironmentFile` 所在目录）。
- 先跑 `plan`，把规划表给用户看，尤其是末尾的「red items」。它只读、不写文件。
- `import` 要求 `hosts/<host>/host.env` 已存在（见 `.claude/skills/deploy/references/deploy-repo.md`）。目标目录已存在时 exit 1，不覆盖。
- `--local <dir>` 把本地目录当源，配合 `--home` 指向源侧家目录的副本；用于离线检查。
- `--dry-run` 打出将执行的 ssh 与将写的路径，不连接、不写。

## 读结果

规划表六段：`artifacts`（每个源产物去哪、靠哪条通道）、`config rewrites`（哪些字面值变成了占位符）、`file credentials`、`skills`、`tools`（源侧 CLI 对 `mise.lock`）、`red items`。红项是需要人判断的：`bypassPermissions`、技能运行路径依赖 docker、工具不在 lock、源 config 里写死了密钥、占位符没有值。映射规则的完整版在 `references/mapping.md`。

`import` 的 stdout 是规划表加 compose 片段；stderr 最后一行给出下一步命令。真值只在 `instances/<name>/` 下的文件里，规划表与片段里没有任何值。

## 交接给用户的步骤

1. 检查 `env`：聊天应用若要换（同一个飞书应用不能有两个 cc-connect 消费者），改 `FEISHU_APP_ID` / `FEISHU_APP_SECRET`，并把 `config.toml` 里的 `allow_from` / `admin_from` 换成新应用下的 open_id。
2. 代理三件（`HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`）按目标主机的出网路径决定留或清空；模型网关地址要能从目标主机访问。
3. 多份 kubeconfig 只保留目标主机该有的那几份，删掉的同时从 `config.toml` 的 `KUBECONFIG` 与 compose 片段里去掉对应项。
4. 把片段贴进 `hosts/<host>/docker-compose.yaml`，`docker compose -f ... config -q` 过，提交部署仓库。
5. 工作区：`deploy` 会建 `workspaces/<name>/` 并 chown；仓库 clone 是在主机上手工做的，属主 UID 1000。
6. 然后走 `deploy` 技能：`plan <host> <name>` 看输出，再 `deploy`，再 `status`。

## 护栏

- 源主机只读：`collect.sh` 没有任何写操作，`scripts/test.sh` 盯着。
- 真值只落 `instances/<name>/`，且 0600；不进 stdout、stderr、日志、chat。规划表里出现值就是 bug。
- 不写 `docker-compose.yaml`，不碰 agentbox 源码目录，不迁会话历史与 `~/.claude.json`。
- 不停、不改源实例；切换由用户在验证新实例之后自己做。
- 完成后跑 `make check`。
```

- [ ] **Step 2: 写 `references/mapping.md`**

把 spec §4 的四张表（4.1 到 4.4）与 §4.5 原文搬过来，标题改为「映射规则」，开头一句「本页是 `render.py` 行为的人读版；改规则先改代码与 `scripts/test.sh`，再改这里」。不加新内容。

- [ ] **Step 3: 改三份文档与 new-instance 边界**

`docs/MULTI_PROJECT.md` §1 末段「新开信任域用仓库自带的 Claude Code 技能 …」之后加一句：

```markdown
已有一台裸机在跑 cc-connect、要换成容器的，用 `.claude/skills/import-instance/SKILL.md`：它只读读取源主机，把配置与凭据按挂载契约写进部署仓库，上线仍走 `deploy`。
```

`README.md` 「开发」一节末段之后加：

```markdown
四个 Claude Code 技能分工：`new-instance` 从模板造实例、`import-instance` 从裸机实例反向导入、`remote-build` 在远端构建镜像、`deploy` 把部署仓库推到主机。都在 `.claude/skills/`。
```

`docs/ROADMAP.md` P1 表：第 4 行「现状」末尾加「2026-09-09 起由 litellm-gateway 迁移 demo 收口：构建机作为第一个 deploy 目标拉 `v0.2.0`」；第 5 行同样加「同一 demo 收口」；表末新增一行：

```markdown
| 5a | `import-instance` 真实源首跑 | 技能与离线测试已实现；从未对真实裸机跑过 `import` | 对 litellm-gateway 源实例 `plan` 与 `import` 各跑通一次，产物经 `deploy plan` 校验通过，并在构建机上起来 |
```

`.claude/skills/new-instance/SKILL.md` 第一段之后加：

```markdown
**边界：** 已经有一台裸机在跑这个实例的，不要用本技能重造；用 `import-instance`（`.claude/skills/import-instance/SKILL.md`）从现状导入。本技能只服务「还没有」的实例。
```

- [ ] **Step 4: 跑 `make check`**

Run: `make check 2>&1 | tail -1`
Expected: `FAIL=0`（文档改动不触发断言，但 `contract consistency` 组会扫 README，确认没碰坏挂载契约表）。

- [ ] **Step 5: 提交**

```bash
git add .claude/skills/import-instance/SKILL.md .claude/skills/import-instance/references/mapping.md docs/MULTI_PROJECT.md README.md docs/ROADMAP.md .claude/skills/new-instance/SKILL.md
git commit -m "docs(import-instance): skill guide, mapping reference, boundaries with new-instance and deploy"
```

---

## Task 8: 端到端：建部署仓库、真实导入、上线到构建机

这是 spec §9。前四步由执行者做，第五步是用户的，之后再由执行者收尾。**真实地址、密钥值只出现在两个 gitignored `.env` 与私有部署仓库里，不进 chat。**

**Files:**
- Create（agentbox 之外）: `~/Sites/github/chinayin/agentbox-deploy/{README.md,hosts/hk-build/host.env,hosts/hk-build/docker-compose.yaml}`
- Create（gitignored）: `.claude/skills/deploy/.env`、`.claude/skills/import-instance/.env`
- Modify: `docs/ROADMAP.md`（验证通过后把第 4、5、5a 行改为已确认并删行）

- [ ] **Step 1: 建部署仓库与两份 `.env`**

```bash
mkdir -p ~/Sites/github/chinayin/agentbox-deploy/hosts/hk-build/instances
cd ~/Sites/github/chinayin/agentbox-deploy && git init -q
printf '# agentbox-deploy\n\n私有部署仓库：每台主机一个目录，真值明文入库，仓库权限是唯一防线。结构与用法见 agentbox 仓库 `.claude/skills/deploy/references/deploy-repo.md`。\n' > README.md
```

`hosts/hk-build/host.env`：`DEPLOY_HOST` / `DEPLOY_KEY` / `DEPLOY_HOST_KEY_ALIAS` 三个值照抄 agentbox 的 `.claude/skills/remote-build/.env`（`AGENTBOX_REMOTE` / `AGENTBOX_REMOTE_KEY` / `AGENTBOX_REMOTE_HOST_KEY_ALIAS`），再加：

```
DEPLOY_DIR=/data/agentbox-demo
AGENTBOX_VERSION=0.2.0
```

`hosts/hk-build/docker-compose.yaml` 先只放：

```yaml
services: {}
volumes: {}
```

agentbox 里：

```bash
printf 'AGENTBOX_DEPLOY_REPO=~/Sites/github/chinayin/agentbox-deploy\n' > .claude/skills/deploy/.env
```

`.claude/skills/import-instance/.env`：`AGENTBOX_IMPORT_SOURCE=root@<源ECS的ip>.sslip.io`、`AGENTBOX_IMPORT_KEY` 同 remote-build 的 key、`AGENTBOX_IMPORT_HOST_KEY_ALIAS=<源ECS的ip>`。源 ECS 的地址用户在对话里给过；写进文件后不再在 chat 里出现。

注意用户 `~/.ssh/known_hosts` 里该主机有一条旧 ECDSA 指纹，主机现在给 ED25519，`StrictHostKeyChecking=accept-new` 会拒。执行前让用户决定：删那一行（`ssh-keygen -R <ip>`）或接受新指纹。不要替用户改 known_hosts。

- [ ] **Step 2: 真实 `plan`**

```bash
.claude/skills/import-instance/scripts/import-instance.sh plan /data/agents/litellm-gateway/.cc-connect
```

把规划表原样给用户看（它不含值）。预期红项：`bypassPermissions`；`docker` 工具在源上存在；`KUBECONFIG` 若是单文件则只有一条挂载；技能里 docker 只在 test.sh。若出现 `placeholder ... has no value` 之类意外红项，先停下报告。

- [ ] **Step 3: 真实 `import`**

```bash
.claude/skills/import-instance/scripts/import-instance.sh import /data/agents/litellm-gateway/.cc-connect --host hk-build --name litellm-gateway
```

把 stdout 末尾的 compose 片段贴进 `hosts/hk-build/docker-compose.yaml`（替换掉空的 `services: {}` / `volumes: {}`），跑：

```bash
cd ~/Sites/github/chinayin/agentbox-deploy && docker compose -f hosts/hk-build/docker-compose.yaml config -q
```

本机若没有 docker，就跳过这条，靠下一步 `deploy plan` 与远端 `compose up` 报错。

- [ ] **Step 4: 用户的手工步骤（不能替做）**

给用户列出，等他完成后再继续：

1. 编辑 `hosts/hk-build/instances/litellm-gateway/env`：`FEISHU_APP_ID` / `FEISHU_APP_SECRET` 换成 demo 应用那一对；`config.toml` 里 `allow_from` / `admin_from` 换成 demo 应用下的 open_id。
2. 决定 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`：构建机直连出网，通常三行都清空（保留键、值为空会让 entrypoint 报占位符缺值；要么删占位符要么给值，推荐从 `config.toml` 的 env 表和 `env` 里一起删掉这三项）。
3. 只留 dev kubeconfig：删掉 prod 那个文件，`config.toml` 的 `KUBECONFIG` 只留 dev 路径，compose 片段去掉 prod 挂载。
4. 确认 `ANTHROPIC_BASE_URL` 能从构建机访问（内网 IP 不行）。
5. `git add -A && git commit -m "hk-build: litellm-gateway imported from the bare-metal host"`。

- [ ] **Step 5: `deploy plan` / `deploy` / `status`**

```bash
.claude/skills/deploy/scripts/deploy.sh plan hk-build litellm-gateway
```

给用户看输出。通过后：

```bash
.claude/skills/deploy/scripts/deploy.sh deploy hk-build litellm-gateway
.claude/skills/deploy/scripts/deploy.sh status hk-build
```

读日志最后 40 行：precheck 通过、cc-connect 起来。`docker compose logs` 里若有 `placeholder references unset variable`，回 Step 4 第 2 条。

- [ ] **Step 6: 工作区与验收**

在构建机上（用 remote-build 的连接方式）：

```bash
ssh <build-host> "install -d -o 1000 -g 1000 -m 0755 /data/agentbox-demo/workspaces/litellm-gateway && cd /data/agentbox-demo && docker compose exec -T litellm-gateway sh -c 'git clone <litellm-gateway 仓库 URL> /workspace/repo'"
```

clone 用容器里的 `GIT_SSH_COMMAND` 与挂进去的 key。若源侧 `work_dir` 就是仓库根，把 `WORK_DIR` 在 compose 里设成 `/workspace/repo` 或 clone 到 `/workspace/.`。

验收，三条都要：

```bash
ssh <build-host> "cd /data/agentbox-demo && docker compose exec -T litellm-gateway sh -c 'curl -sS -m 20 \"\$ANTHROPIC_BASE_URL/v1/messages\" -H \"x-api-key: \$ANTHROPIC_AUTH_TOKEN\" -H \"anthropic-version: 2023-06-01\" -H \"content-type: application/json\" -d \"{\\\"model\\\":\\\"\$ANTHROPIC_MODEL\\\",\\\"max_tokens\\\":16,\\\"messages\\\":[{\\\"role\\\":\\\"user\\\",\\\"content\\\":\\\"ping\\\"}]}\"' | head -c 300"
ssh <build-host> "docker inspect agentbox-litellm-gateway --format '{{.HostConfig.PidsLimit}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}'"
```

Expected：第一条返回含 `content`；第二条打出 `512 [ALL] [no-new-privileges:true]`。第三条是用户在飞书 demo 应用里发一条消息拿到回复。

- [ ] **Step 7: 收尾**

- `docs/ROADMAP.md`：第 4 行（GHCR 被服务器拉取）、第 5 行（deploy 首跑）、5a 行（import 首跑）验收全部满足则删行；若第 6 行的 `docker inspect` 三项读到，把该行「现状」改为「2026-09-09 在 hk-build 上读到 `PidsLimit`/`CapDrop`/`SecurityOpt` 生效；healthcheck 与 `read_only` 仍未做」。
- 源 ECS 的 systemd 实例不动。何时停、怎么切由用户另行决定。
- `make check`，提交 agentbox；部署仓库单独提交。

```bash
git add docs/ROADMAP.md && git commit -m "docs(roadmap): GHCR pull, deploy and import verified on the first real host"
```

---

## 自查

**Spec 覆盖：** §3 采集项 → Task 2；§4.1 改写 → Task 3/4；§4.2 凭据 → Task 4（复制）+ Task 5（服务器权限）；§4.3 技能 → Task 2/4；§4.4 工具 → Task 3；§4.5 工作区 → Task 3 规划文本 + Task 8 Step 6；§5 接口 → Task 1/4；§6 分工 → Task 6/7；§7 护栏 1-5 → Task 2（只读）、Task 4（不上屏、不覆盖、不越界）、Task 1（无 IP）；§8 测试 → Task 1-6 的断言逐条对应；§9 首次使用 → Task 8；§10 文件 → Task 7；§11 非目标未被任何任务越过。

**类型一致：** 清单记录名（`env_key`、`kube_file`、`ssh_key`、`user_skill`、`ws_skill`、`skill_lock`、`tool`、`unit`）在 Task 2 定义、Task 3/4 消费，拼写一致；复制清单 `kind\tsrc\tdst` 三种 kind（`cred`/`dir`/`file`）在 Task 4 两端一致；`LOCKS`、`INVENTORY`、`TARGET`、`HOST_DIR` 在驱动内跨任务共用，Task 1 声明 `TARGET`/`HOST_DIR`，Task 2 声明 `INVENTORY`，Task 3 声明 `LOCKS`。
