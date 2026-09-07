# 发布技能实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 agentbox 加一个 `deploy` 技能，把部署仓库里某台主机的实例配置和密钥投放到该主机，用 GHCR 上的版本化镜像起容器。

**Architecture:** 技能代码住 agentbox 的 `.claude/skills/deploy/`，形状照抄同仓库的 `remote-build`：主机与路径三级覆盖（flag > 环境变量 > 技能 `.env`），ssh 走可选 SOCKS 代理，日志 tee 回 `runtime/`。数据住另一个私有仓库 `agentbox-deploy`，按主机分目录。三个动作：`plan` 全离线校验并打印影响面，`deploy` 推配置起容器，`status` 看远端状态。

**Tech Stack:** bash + rsync + ssh + docker compose；测试是 `scripts/test.sh` 里新增的断言组，由 `make check` 驱动；占位符解析用 python3 的 tomllib。

**Spec:** `docs/superpowers/specs/2026-09-07-deploy-skill-design.md`

## Global Constraints

- 脚本内的注释、帮助文本、报错、日志、测试用例名**一律英文**。项目 `CLAUDE.md` 的这条要求覆盖 `gox-code-rules:shell` 技能里的中文要求，现有 `remote-build.sh` 即是范例。文档类（`docs/`、`README.md`）保持中文。
- 每个脚本以 `#!/usr/bin/env bash` 开头，紧跟 `set -euo pipefail`。所有展开加引号。
- 退出码固定为：`0` 成功 / `1` 用法错误或远端命令失败 / `2` 前置条件不满足（缺 ssh、rsync、主机不可达）。帮助文本里要列出这三条。
- stdout 只放数据，本技能里就是日志路径。进度、警告、诊断全部到 stderr。无 emoji 无颜色。
- 破坏性动作默认拒绝，要显式 `--force` 才放行。
- `.env.example` 里不得出现真实主机地址或密钥，唯一允许的 IP 字面量是 `127.0.0.1`（SOCKS 示例）。`scripts/test.sh` 已有同类断言在盯 `remote-build`，新技能照同样标准。
- 每个任务结束前跑 `make check`，它包含 `shellcheck -x -S warning`。红了不许进下一个任务。
- 真实密钥、真实主机地址不进 git、不进文档、不进对话。

---

## Task 1: 前置条件验证（人工，需用户授权）

**这是一道闸门，不是代码任务。** 它失败的话 Task 2 之后全部作废，spec 第 4 到 6 节要改回在服务器上从源码构建。

`v*` tag 发布链路从未跑过，GHCR 上现在没有任何 agentbox 镜像。技能写完也没有镜像可拉。

**Files:** 无。只改 `docs/ROADMAP.md`（在 Task 11 里一并做）。

- [ ] **Step 1: 向用户确认打 tag**

打 tag 会触发 CI 构建并把镜像推到 GHCR，是对外且不可逆的操作。执行者不得自行决定，必须先问。确认后由用户或经用户明确授权执行：

```bash
git tag v0.1.0
git push origin v0.1.0
```

- [ ] **Step 2: 确认 release.yml 先跑 ci 再发布**

在 GitHub Actions 里看 `release` 工作流：`ci` job 必须先绿，`publish` job 才开始。这是 `release.yml` 里 `needs: ci` 的行为，第一次跑要亲眼确认。

- [ ] **Step 3: 确认两个多架构镜像真的推上去了**

```bash
docker buildx imagetools inspect ghcr.io/<owner>/agentbox:0.1.0
docker buildx imagetools inspect ghcr.io/<owner>/agentbox:0.1.0-pi
```

Expected: 两条都列出 `linux/amd64` 和 `linux/arm64` 两个 manifest。

- [ ] **Step 4: 在目标服务器上验证私有拉取**

GHCR 上的镜像随私有仓库一起是私有的。在服务器上用一个只有 `read:packages` 权限的 PAT 登录一次，凭据会落在服务器的 `~/.docker/config.json`：

```bash
echo "$GHCR_PAT" | docker login ghcr.io -u <user> --password-stdin
docker pull ghcr.io/<owner>/agentbox:0.1.0
```

Expected: pull 成功。失败信息里出现 `denied` 或 `unauthorized` 说明 PAT 权限不对或没登录。这个 PAT 是人工步骤，技能不代管、不写进任何文件。

- [ ] **Step 5: 记录结论**

把实际用到的版本号记下来，Task 8 的 fixture 和文档示例都引用它。如果这一步没过，停下来找用户重新决策，不要继续。

---

## Task 2: 技能骨架与配置三级覆盖

**Files:**
- Create: `.claude/skills/deploy/scripts/deploy.sh`
- Create: `.claude/skills/deploy/.env.example`
- Modify: `scripts/test.sh`（在 `remote-build skill` 组之后、`template hygiene` 组之前插入新组）

**Interfaces:**
- Produces: 脚本接受 `--repo PATH`、`--dry-run`、`-v/--verbose`、`-h/--help`，以及位置参数 `<action> [host] [instance]`。部署仓库路径来源优先级为 flag > 环境变量 `AGENTBOX_DEPLOY_REPO` > 技能 `.env`。后续任务在此基础上加动作实现。

- [ ] **Step 1: 写失败的断言**

在 `scripts/test.sh` 里 `grep -qxF '.claude/skills/*/.env' "$ROOT/.gitignore"` 那一行之后、`group "template hygiene"` 之前，插入：

```bash
# ---------- deploy skill ----------
# Same three-level override as remote-build: the skill .env only fills what is still unset, so the
# environment and flags always win, and with no source at all the script must stop instead of
# operating on an empty path.
group "deploy skill"
DP_SRC="$ROOT/.claude/skills/deploy/scripts/deploy.sh"
dp="$TMP/dp"; mkdir -p "$dp/skill/scripts"; cp "$DP_SRC" "$dp/skill/scripts/"
mkdir -p "$dp/repo/hosts/h1/instances/a1" "$dp/other/hosts/h2"
printf 'AGENTBOX_DEPLOY_REPO=%s\n' "$dp/repo" > "$dp/skill/.env"
bash "$dp/skill/scripts/deploy.sh" --help >/dev/null 2>&1 \
	&& ok "deploy --help exits 0" || bad "deploy --help exits 0" ""
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run plan h1 2>&1)"; rc=$?
grep -q "$dp/repo" <<<"$out" \
	&& ok "deploy reads the repo path from the skill .env" || bad "deploy reads the repo path from the skill .env" "rc=$rc $out"
out="$(AGENTBOX_DEPLOY_REPO="$dp/other" bash "$dp/skill/scripts/deploy.sh" --dry-run plan h2 2>&1)"
grep -q "$dp/other" <<<"$out" && ! grep -q "$dp/repo" <<<"$out" \
	&& ok "environment overrides the deploy skill .env" || bad "environment overrides the deploy skill .env" "$out"
out="$(bash "$dp/skill/scripts/deploy.sh" --repo "$dp/other" --dry-run plan h2 2>&1)"
grep -q "$dp/other" <<<"$out" && ok "flag overrides the deploy skill .env" || bad "flag overrides the deploy skill .env" "$out"
rm "$dp/skill/.env"
env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" plan h1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "deploy without any repo source exits 1" || bad "deploy without any repo source exits 1" "rc=$rc"
printf 'AGENTBOX_DEPLOY_REPO=%s\n' "$dp/repo" > "$dp/skill/.env"
[ -f "$ROOT/.claude/skills/deploy/.env.example" ] && ! grep -v '127\.0\.0\.1' "$ROOT/.claude/skills/deploy/.env.example" | grep -qE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
	&& ok "deploy .env.example carries no real address" || bad "deploy .env.example carries no real address" ""
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `bash scripts/test.sh 2>&1 | grep -A2 'deploy skill'`
Expected: FAIL，因为 `.claude/skills/deploy/scripts/deploy.sh` 不存在，`cp` 报错。

- [ ] **Step 3: 写 .env.example**

Create `.claude/skills/deploy/.env.example`：

```
# Local path to the private deploy repository for the deploy skill. Copy to .env (gitignored);
# flags and environment variables override it. No host addresses or secrets belong in this file:
# those live in the deploy repo, one host.env per host.
AGENTBOX_DEPLOY_REPO=~/path/to/agentbox-deploy
```

- [ ] **Step 4: 写脚本骨架**

Create `.claude/skills/deploy/scripts/deploy.sh`：

```bash
#!/usr/bin/env bash
# Publish agentbox instances to a remote docker host. Configuration and secrets come from a
# separate private deploy repository, one directory per host; images come from GHCR by version.
# The repo path comes from, in order of precedence: --repo, AGENTBOX_DEPLOY_REPO, the skill's .env
# file (../.env next to this script, gitignored; template in ../.env.example).
# Per-host connection details live in the deploy repo at hosts/<host>/host.env and never in here.
# Exit codes: 0 ok / 1 usage error or remote failure / 2 precondition (unreachable, missing tools)

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "${SKILL_DIR}/../../.." && pwd)"

# .env fills only variables that are still unset, so the environment and flags always win.
# A leading ~/ in a value is expanded; nothing else is interpreted.
if [ -f "${SKILL_DIR}/.env" ]; then
	while IFS= read -r line || [ -n "${line}" ]; do
		case "${line}" in ''|\#*) continue ;; esac
		name="${line%%=*}"; val="${line#*=}"
		case "${name}" in AGENTBOX_DEPLOY_REPO) ;; *) continue ;; esac
		# shellcheck disable=SC2088  # matching a literal leading ~/ from the file is the point here
		case "${val}" in "~/"*) val="${HOME}/${val#\~/}" ;; esac
		[ -n "${!name:-}" ] || export "${name}=${val}"
	done < "${SKILL_DIR}/.env"
fi

REPO="${AGENTBOX_DEPLOY_REPO:-}"
LOG_DIR="${ROOT}/runtime/deploy"
ACTION=""
HOST=""
INSTANCE=""
FORCE=0
VERBOSE=0
DRY_RUN=0

die()  { echo "error: $*" >&2; exit 1; }
pre()  { echo "error: $*" >&2; exit 2; }
warn() { echo "warning: $*" >&2; }
step() { echo "==> $*" >&2; }
vlog() { [ "${VERBOSE}" -eq 1 ] && echo "verbose: $*" >&2 || true; }

usage() {
	cat <<'USAGE'
Usage: deploy.sh [options] <action> [host] [instance]

Actions:
  plan     HOST [INSTANCE]   validate locally and print the impact; never connects
  deploy   HOST [INSTANCE]   push config and secrets, pull the image, start containers
  status   HOST              remote container state and recent logs

Options:
      --repo PATH    deploy repository (or the AGENTBOX_DEPLOY_REPO environment variable)
      --force        proceed even though the deploy repo has uncommitted changes
      --dry-run      only print the commands that would run
  -v, --verbose      extra diagnostics (to stderr)
  -h, --help         show this help

The deploy repo path can live in the skill's .env file (.claude/skills/deploy/.env, gitignored;
copy .env.example). Flags and environment win. Per-host connection details and the target image
version live in the deploy repo at hosts/<host>/host.env.

Deploy logs are written to runtime/deploy/<timestamp>-<action>-<host>.log under the repo root.

Exit codes: 0 success / 1 usage error or remote command failure / 2 precondition not met
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)  REPO="${2:?missing value}"; shift 2 ;;
		--force) FORCE=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-v|--verbose) VERBOSE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*) usage >&2; die "unknown option: $1" ;;
		plan|deploy|status)
			[ -n "${ACTION}" ] && { usage >&2; die "only one action is allowed"; }
			ACTION="$1"; shift ;;
		*)
			if [ -z "${ACTION}" ]; then usage >&2; die "unknown action: $1"; fi
			if   [ -z "${HOST}" ];     then HOST="$1"
			elif [ -z "${INSTANCE}" ]; then INSTANCE="$1"
			else usage >&2; die "unexpected argument: $1"; fi
			shift ;;
	esac
done

[ -n "${ACTION}" ] || { usage >&2; die "an action is required"; }
[ -n "${REPO}" ]   || { usage >&2; die "--repo, AGENTBOX_DEPLOY_REPO, or AGENTBOX_DEPLOY_REPO in ${SKILL_DIR}/.env is required"; }
[ -d "${REPO}" ]   || die "deploy repo ${REPO} is not a directory"
[ -n "${HOST}" ]   || { usage >&2; die "a host is required"; }

main() {
	case "${ACTION}" in
		plan)   step "planning ${HOST} from ${REPO}" ;;
		deploy) step "deploying ${HOST} from ${REPO}" ;;
		status) step "querying ${HOST} from ${REPO}" ;;
	esac
}

main
```

- [ ] **Step 5: 跑测试确认通过**

Run: `bash scripts/test.sh 2>&1 | sed -n '/deploy skill/,/template hygiene/p'`
Expected: 6 条全 PASS。

- [ ] **Step 6: 跑完整门禁**

Run: `make check`
Expected: exit 0，`FAIL=0`，shellcheck 无告警。

- [ ] **Step 7: 提交**

```bash
git add .claude/skills/deploy/scripts/deploy.sh .claude/skills/deploy/.env.example scripts/test.sh
git commit -m "deploy: skill skeleton with three-level repo path resolution"
```

---

## Task 3: 主机解析与 host.env

**Files:**
- Modify: `.claude/skills/deploy/scripts/deploy.sh`
- Modify: `scripts/test.sh`

**Interfaces:**
- Consumes: Task 2 的 `REPO`、`HOST`、`die`、`pre`。
- Produces: `load_host_env()` 把 `hosts/<HOST>/host.env` 读进以下全局变量，缺 `DEPLOY_HOST` 即 exit 1：`DEPLOY_HOST`、`DEPLOY_KEY`、`DEPLOY_HOST_KEY_ALIAS`、`DEPLOY_SOCKS`、`DEPLOY_DIR`（默认 `/data/agentbox`）、`AGENTBOX_VERSION`。另外产出 `SSH_OPTS` 数组和 `list_instances()`。

- [ ] **Step 1: 写失败的断言**

在 deploy skill 组末尾追加：

```bash
env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run plan nosuchhost >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "deploy rejects an unknown host (exit 1)" || bad "deploy rejects an unknown host (exit 1)" "rc=$rc"
printf 'DEPLOY_DIR=/data/agentbox\n' > "$dp/repo/hosts/h1/host.env"
env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run plan h1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "deploy rejects a host.env without DEPLOY_HOST (exit 1)" || bad "deploy rejects a host.env without DEPLOY_HOST (exit 1)" "rc=$rc"
printf 'DEPLOY_HOST=user@h1.example.test\nDEPLOY_DIR=/data/agentbox\nAGENTBOX_VERSION=0.1.0\n' > "$dp/repo/hosts/h1/host.env"
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run plan h1 2>&1)"
grep -q 'user@h1.example.test' <<<"$out" && grep -q '0.1.0' <<<"$out" \
	&& ok "deploy reads host and version from host.env" || bad "deploy reads host and version from host.env" "$out"
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `bash scripts/test.sh 2>&1 | sed -n '/deploy skill/,/template hygiene/p'`
Expected: 三条新断言 FAIL，因为脚本还不读 `host.env`，未知主机也不报错。

- [ ] **Step 3: 实现**

在 deploy.sh 的 `main()` 之前插入：

```bash
HOST_DIR="${REPO}/hosts/${HOST}"
DEPLOY_HOST=""
DEPLOY_KEY=""
DEPLOY_HOST_KEY_ALIAS=""
DEPLOY_SOCKS=""
DEPLOY_DIR="/data/agentbox"
AGENTBOX_VERSION=""
declare -a SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new)

# hosts/<host>/host.env: connection fields stay local, AGENTBOX_VERSION is derived to the remote.
load_host_env() {
	local f="${HOST_DIR}/host.env" line name val
	[ -d "${HOST_DIR}" ] || die "host ${HOST} not found in ${REPO}/hosts"
	[ -f "${f}" ] || die "missing ${f}"
	while IFS= read -r line || [ -n "${line}" ]; do
		case "${line}" in ''|\#*) continue ;; esac
		name="${line%%=*}"; val="${line#*=}"
		case "${name}" in
			DEPLOY_HOST|DEPLOY_KEY|DEPLOY_HOST_KEY_ALIAS|DEPLOY_SOCKS|DEPLOY_DIR|AGENTBOX_VERSION) ;;
			*) continue ;;
		esac
		# shellcheck disable=SC2088  # matching a literal leading ~/ from the file is the point here
		case "${val}" in "~/"*) val="${HOME}/${val#\~/}" ;; esac
		printf -v "${name}" '%s' "${val}"
	done < "${f}"
	[ -n "${DEPLOY_HOST}" ] || die "${f} does not set DEPLOY_HOST"
	[ -n "${AGENTBOX_VERSION}" ] || die "${f} does not set AGENTBOX_VERSION"
	[ -n "${DEPLOY_KEY}" ] && SSH_OPTS+=(-i "${DEPLOY_KEY}")
	# BSD nc SOCKS5 syntax; ssh substitutes %h %p.
	[ -n "${DEPLOY_SOCKS}" ] && SSH_OPTS+=(-o "ProxyCommand=nc -X 5 -x ${DEPLOY_SOCKS} %h %p")
	[ -n "${DEPLOY_HOST_KEY_ALIAS}" ] && SSH_OPTS+=(-o "HostKeyAlias=${DEPLOY_HOST_KEY_ALIAS}")
	return 0
}

# Instances to act on: the one named on the command line, or every directory under instances/.
list_instances() {
	local d
	if [ -n "${INSTANCE}" ]; then
		[ -d "${HOST_DIR}/instances/${INSTANCE}" ] || die "instance ${INSTANCE} not found under ${HOST_DIR}/instances"
		echo "${INSTANCE}"
		return 0
	fi
	for d in "${HOST_DIR}"/instances/*/; do
		[ -d "${d}" ] || continue
		basename "${d}"
	done
}
```

把 `main()` 改成：

```bash
main() {
	load_host_env
	case "${ACTION}" in
		plan)   step "planning ${HOST} (${DEPLOY_HOST}) version ${AGENTBOX_VERSION} from ${REPO}" ;;
		deploy) step "deploying ${HOST} (${DEPLOY_HOST}) version ${AGENTBOX_VERSION} from ${REPO}" ;;
		status) step "querying ${HOST} (${DEPLOY_HOST}) from ${REPO}" ;;
	esac
}
```

注意 `printf -v` 是 bash 3.2 起就有的间接赋值，比 `eval` 安全；`declare -g` 在 macOS 自带的 bash 3.2 上不可用，不要用它。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh 2>&1 | sed -n '/deploy skill/,/template hygiene/p'`
Expected: 9 条全 PASS。注意 Task 2 的第二条断言现在要求 `host.env` 存在，`h2` 目录也要补一份，否则会退化成 exit 1。如果那条红了，在 fixture 里给 `$dp/other/hosts/h2` 也写一份 `host.env`。

- [ ] **Step 5: 跑完整门禁**

Run: `make check`
Expected: exit 0。

- [ ] **Step 6: 提交**

```bash
git add .claude/skills/deploy/scripts/deploy.sh scripts/test.sh
git commit -m "deploy: resolve host and target version from the deploy repo"
```

---

## Task 4: 本地占位符校验

把 entrypoint 的 exit 2 提前到本地，缺值时不连服务器。

**Files:**
- Modify: `.claude/skills/deploy/scripts/deploy.sh`
- Modify: `scripts/test.sh`

**Interfaces:**
- Consumes: Task 3 的 `HOST_DIR`、`list_instances`、`die`。
- Produces: `config_placeholders <toml>` 打印该 config 引用的变量名，一行一个，正则与 `entrypoint.sh` 的 `placeholders()` 完全相同；`check_instance <name>` 比对 `env` 文件里的变量名，缺失则打印全部缺失项并返回 1。

- [ ] **Step 1: 写失败的断言**

```bash
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
printf 'ANTHROPIC_AUTH_TOKEN=sk-x\nFEISHU_APP_ID=cli_x\n' > "$dp/repo/hosts/h1/instances/a1/env"
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run plan h1 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'FEISHU_APP_SECRET' <<<"$out" \
	&& ok "deploy names the missing placeholder and exits 1" || bad "deploy names the missing placeholder and exits 1" "rc=$rc $out"
printf 'ANTHROPIC_AUTH_TOKEN=sk-x\nFEISHU_APP_ID=cli_x\nFEISHU_APP_SECRET=x\n' > "$dp/repo/hosts/h1/instances/a1/env"
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run plan h1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "deploy plan passes once every placeholder has a value" || bad "deploy plan passes once every placeholder has a value" "rc=$rc $out"
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `bash scripts/test.sh 2>&1 | sed -n '/deploy skill/,/template hygiene/p'`
Expected: 第一条新断言 FAIL，脚本此刻还不校验，rc 是 0 不是 1。

- [ ] **Step 3: 实现**

```bash
# ${VAR} names referenced by string values in the config (real TOML parse: comments do not count).
# The regex must stay identical to the placeholders() function in entrypoint.sh; scripts/test.sh
# asserts the two agree, because a mismatch here means deploy passes and the container then fails.
config_placeholders() {
	python3 - "$1" <<'PY'
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

# WORK_DIR comes from the compose file, not the env file, so it is not required here.
check_instance() {
	local name="$1" dir toml envf want have missing=()
	dir="${HOST_DIR}/instances/${name}"
	toml="${dir}/config.toml"
	envf="${dir}/env"
	[ -f "${toml}" ] || die "missing ${toml}"
	[ -f "${envf}" ] || die "missing ${envf}"
	want="$(config_placeholders "${toml}")" || die "config ${toml} is not valid TOML (see above)"
	have="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "${envf}" | tr -d '=' | sort -u)"
	local v
	for v in ${want}; do
		[ "${v}" = WORK_DIR ] && continue
		grep -qxF "${v}" <<<"${have}" || missing+=("${v}")
	done
	if [ "${#missing[@]}" -gt 0 ]; then
		echo "error: instance ${name} references environment variables with no value in ${envf}:" >&2
		printf '  - %s\n' "${missing[@]}" >&2
		return 1
	fi
	vlog "instance ${name}: $(wc -w <<<"${want}") placeholders all resolved"
	return 0
}

check_all_instances() {
	local n rc=0 count=0
	while IFS= read -r n; do
		[ -n "${n}" ] || continue
		count=$((count+1))
		check_instance "${n}" || rc=1
	done < <(list_instances)
	[ "${count}" -gt 0 ] || die "no instances found under ${HOST_DIR}/instances"
	[ "${rc}" -eq 0 ] || die "fix the env files above before deploying"
	return 0
}
```

在 `main()` 的 `plan` 与 `deploy` 分支里调用 `check_all_instances`：

```bash
main() {
	load_host_env
	case "${ACTION}" in
		plan)
			step "planning ${HOST} (${DEPLOY_HOST}) version ${AGENTBOX_VERSION} from ${REPO}"
			check_all_instances
			;;
		deploy)
			step "deploying ${HOST} (${DEPLOY_HOST}) version ${AGENTBOX_VERSION} from ${REPO}"
			check_all_instances
			;;
		status) step "querying ${HOST} (${DEPLOY_HOST}) from ${REPO}" ;;
	esac
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh 2>&1 | sed -n '/deploy skill/,/template hygiene/p'`
Expected: 11 条全 PASS。

- [ ] **Step 5: 跑完整门禁**

Run: `make check`
Expected: exit 0。

- [ ] **Step 6: 提交**

```bash
git add .claude/skills/deploy/scripts/deploy.sh scripts/test.sh
git commit -m "deploy: validate every instance placeholder locally before connecting"
```

---

## Task 5: 占位符实现一致性契约

这条断言修正 spec 第 8 节的表述。spec 说"三处实现输出一致"，但 `scripts/test.sh` 里那份服务于 scaffold 模板校验，正则只认大写且有意丢掉 `WORK_DIR`，与另外两处语义不同，强行要求三者一致只会得到一条必须放水的断言。

真正需要锁住的是 `deploy.sh` 与 `entrypoint.sh` 这两处：前者决定"本地放不放行"，后者决定"容器里报不报错"。两者漂移就会出现本地过、容器崩的静默失配。`test.sh` 那份不纳入。

**Files:**
- Modify: `scripts/test.sh`（加进已有的 `contract consistency` 组）

**Interfaces:**
- Consumes: Task 4 的 `config_placeholders`；`entrypoint.sh` 的 `placeholders`。

- [ ] **Step 1: 写失败的断言**

先确认 `contract consistency` 组的位置：

Run: `grep -n 'contract consistency' scripts/test.sh`

在该组内追加。两个函数都只依赖 python3，可以在宿主上直接取出来跑：

```bash
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
```

`DP_SRC` 在 `deploy skill` 组里定义，而 `contract consistency` 组在它之前，所以要么把 `DP_SRC` 的定义上移到文件顶部的常量区（跟 `ENTRY`、`DF` 放在一起），要么把这条断言放到 `deploy skill` 组里。**选前者**：`DP_SRC` 是路径常量，和 `ENTRY` 同性质，放顶部更合规。

- [ ] **Step 2: 跑测试确认它失败**

先故意把 `deploy.sh` 里的正则改成 `[A-Z_]+`，跑：

Run: `bash scripts/test.sh 2>&1 | grep 'same placeholder names'`
Expected: FAIL，输出里 entrypoint 那侧有 `lower_name` 和 `Mixed_9`，deploy 那侧没有。

- [ ] **Step 3: 把正则改回去**

把 `deploy.sh` 的正则恢复为 `[A-Za-z_][A-Za-z0-9_]*`。这一步只是撤销 Step 2 的临时破坏，代码内容与 Task 4 交付的一致。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh 2>&1 | grep 'same placeholder names'`
Expected: PASS。

- [ ] **Step 5: 跑完整门禁**

Run: `make check`
Expected: exit 0。

- [ ] **Step 6: 提交**

```bash
git add scripts/test.sh
git commit -m "test: pin deploy and entrypoint to the same placeholder grammar"
```

---

## Task 6: 脏仓库护栏与 --force

部署仓库有未提交改动时，服务器上跑的是哪个 commit 就说不清了。默认拒绝。

**Files:**
- Modify: `.claude/skills/deploy/scripts/deploy.sh`
- Modify: `scripts/test.sh`

**Interfaces:**
- Consumes: Task 3 的 `REPO`、`FORCE`、`die`、`warn`。
- Produces: `check_repo_clean()`。非 git 仓库时只警告不拦，因为部署仓库是不是 git 由用户决定。

- [ ] **Step 1: 写失败的断言**

```bash
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
```

注意最后一行把 fixture 还原成 clean，否则后续任务新增的断言会踩到脏状态。

- [ ] **Step 2: 跑测试确认它失败**

Run: `bash scripts/test.sh 2>&1 | sed -n '/deploy skill/,/template hygiene/p'`
Expected: 脏仓库那条 FAIL，脚本此刻不看 git 状态。

- [ ] **Step 3: 实现**

```bash
# A deploy from a dirty repo cannot be traced back to a commit. Refuse unless --force says otherwise.
check_repo_clean() {
	if ! git -C "${REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		warn "deploy repo ${REPO} is not a git repository; there is no commit to trace this deploy to"
		return 0
	fi
	local dirty
	dirty="$(git -C "${REPO}" status --porcelain)"
	[ -z "${dirty}" ] && return 0
	if [ "${FORCE}" -eq 1 ]; then
		warn "deploy repo has uncommitted changes; proceeding because --force was given"
		return 0
	fi
	echo "error: deploy repo ${REPO} has uncommitted changes:" >&2
	sed 's/^/  /' <<<"${dirty}" >&2
	echo "commit them so the deployed state maps to a commit, or pass --force" >&2
	exit 1
}
```

在 `main()` 的 `plan` 与 `deploy` 分支里，`check_all_instances` 之前调用 `check_repo_clean`。`status` 不调用，它只读远端状态，与本地是否干净无关。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh 2>&1 | sed -n '/deploy skill/,/template hygiene/p'`
Expected: 14 条全 PASS。

- [ ] **Step 5: 跑完整门禁**

Run: `make check`
Expected: exit 0。

- [ ] **Step 6: 提交**

```bash
git add .claude/skills/deploy/scripts/deploy.sh scripts/test.sh
git commit -m "deploy: refuse to publish from a dirty deploy repo without --force"
```

---

## Task 7: plan 打印影响面

`plan` 到此已经做完全部校验，还缺把影响面说清楚：同步哪些文件、什么版本、会重启哪些容器。它必须全程离线。

**Files:**
- Modify: `.claude/skills/deploy/scripts/deploy.sh`
- Modify: `scripts/test.sh`

**Interfaces:**
- Consumes: Task 3 到 6 的全部。
- Produces: `print_plan()`，输出到 stderr（它是给人看的进度信息，不是数据）。

- [ ] **Step 1: 写失败的断言**

```bash
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" plan h1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'a1' <<<"$out" && grep -q '0.1.0' <<<"$out" && grep -q 'restart' <<<"$out" \
	&& ok "plan lists the instances, the version and what will restart" || bad "plan lists the instances, the version and what will restart" "rc=$rc $out"
# plan must never dial the host: a bogus proxy would make any connection attempt fail loudly
printf 'DEPLOY_HOST=user@h1.example.test\nDEPLOY_DIR=/data/agentbox\nAGENTBOX_VERSION=0.1.0\nDEPLOY_SOCKS=127.0.0.1:1\n' > "$dp/repo/hosts/h1/host.env"
env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" plan h1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "plan stays offline even with an unusable proxy" || bad "plan stays offline even with an unusable proxy" "rc=$rc"
printf 'DEPLOY_HOST=user@h1.example.test\nDEPLOY_DIR=/data/agentbox\nAGENTBOX_VERSION=0.1.0\n' > "$dp/repo/hosts/h1/host.env"
( cd "$dp/repo" && git add -A && git -c user.email=t@e.test -c user.name=t commit -qm hostenv ) 2>/dev/null
```

注意 `plan` 这里不加 `--dry-run`，因为 `plan` 本身就不改任何东西；`--dry-run` 是给 `deploy` 用的。第二条断言用一个指向 127.0.0.1:1 的死代理，任何真实连接都会失败，`plan` 仍须 exit 0，这就证明了它没连。

- [ ] **Step 2: 跑测试确认它失败**

Run: `bash scripts/test.sh 2>&1 | grep -E 'plan lists|plan stays offline'`
Expected: 第一条 FAIL，输出里没有 `restart` 字样。

- [ ] **Step 3: 实现**

```bash
# Everything print_plan reports is computed from local files; it must not connect.
print_plan() {
	local n compose="${HOST_DIR}/docker-compose.yaml"
	echo "  repo:      ${REPO}" >&2
	echo "  host:      ${DEPLOY_HOST}  dir ${DEPLOY_DIR}" >&2
	echo "  version:   ${AGENTBOX_VERSION}" >&2
	if [ -f "${compose}" ]; then
		echo "  compose:   ${compose}" >&2
	else
		echo "  compose:   MISSING (${compose})" >&2
	fi
	echo "  will sync: docker-compose.yaml, instances/ (config.toml + env, env as 0600)" >&2
	echo "  will restart these containers, interrupting any session in progress:" >&2
	while IFS= read -r n; do
		[ -n "${n}" ] || continue
		echo "    - ${n}" >&2
	done < <(list_instances)
}
```

`main()` 的 `plan` 分支在校验之后调用 `print_plan`。`deploy` 分支也调用它，先说清影响面再动手。

`print_plan` 里 compose 缺失只报告不中断，因为 Task 8 的 `do_deploy` 会在真正同步前把它变成硬错误。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh 2>&1 | sed -n '/deploy skill/,/template hygiene/p'`
Expected: 16 条全 PASS。

- [ ] **Step 5: 跑完整门禁**

Run: `make check`
Expected: exit 0。

- [ ] **Step 6: 提交**

```bash
git add .claude/skills/deploy/scripts/deploy.sh scripts/test.sh
git commit -m "deploy: print the full impact of a plan without connecting"
```

---

## Task 8: deploy 动作

**Files:**
- Modify: `.claude/skills/deploy/scripts/deploy.sh`
- Modify: `scripts/test.sh`

**Interfaces:**
- Consumes: 前面全部。
- Produces: `rssh`、`make_rsync_ssh`、`sync_host`、`remote_up`、`do_deploy`。成功时唯一的 stdout 输出是日志路径。

- [ ] **Step 1: 写失败的断言**

```bash
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
! grep -qE "rsync[^\n]*($ROOT/(Dockerfile|entrypoint.sh|scripts|mise)|--exclude)" <<<"$out" \
	&& grep -q "$dp/repo/hosts/h1/" <<<"$out" \
	&& ok "rsync source is the host directory only, no agentbox source" || bad "rsync source is the host directory only, no agentbox source" "$out"
grep -q 'AGENTBOX_VERSION=0.1.0' <<<"$out" \
	&& ok "the remote .env is derived, not synced" || bad "the remote .env is derived, not synced" "$out"
! grep -qE 'DEPLOY_KEY|DEPLOY_SOCKS|DEPLOY_HOST=' <<<"$out" \
	&& ok "connection fields never reach the remote .env" || bad "connection fields never reach the remote .env" "$out"
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `bash scripts/test.sh 2>&1 | sed -n '/deploy skill/,/template hygiene/p'`
Expected: 五条新断言 FAIL，`deploy` 分支目前只打印计划。

- [ ] **Step 3: 实现**

```bash
# All remote commands go through here; ssh exit code passes through.
rssh() {
	vlog "ssh ${DEPLOY_HOST}: $*"
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "plan: ssh ${DEPLOY_HOST} -- $*" >&2
		return 0
	fi
	ssh "${SSH_OPTS[@]}" "${DEPLOY_HOST}" "$@"
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

# Whitelist transport, one direction only: the host directory's compose file and instances/. The
# agentbox source tree is never involved, and nothing is ever pulled back from the server.
sync_host() {
	local compose="${HOST_DIR}/docker-compose.yaml"
	[ -f "${compose}" ] || die "missing ${compose}"
	step "syncing ${HOST} config to ${DEPLOY_HOST}:${DEPLOY_DIR}"
	local tmp
	tmp="$(mktemp -d)"
	# shellcheck disable=SC2064  # expand tmp now, on purpose
	trap "rm -rf '${tmp}'" RETURN
	make_rsync_ssh "${tmp}/ssh"
	local -a args=(-a --delete)
	[ "${VERBOSE}" -eq 1 ] && args+=(-v)
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "plan: rsync ${args[*]} ${HOST_DIR}/docker-compose.yaml ${HOST_DIR}/instances ${DEPLOY_HOST}:${DEPLOY_DIR}/" >&2
	else
		rssh "install -d -m 0755 '${DEPLOY_DIR}'"
		rsync "${args[@]}" -e "${tmp}/ssh" \
			"${HOST_DIR}/docker-compose.yaml" "${HOST_DIR}/instances" \
			"${DEPLOY_HOST}:${DEPLOY_DIR}/"
	fi
	# The remote .env is derived from host.env, never synced: connection fields stay local.
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "plan: write ${DEPLOY_DIR}/.env with AGENTBOX_VERSION=${AGENTBOX_VERSION}" >&2
		echo "plan: chmod 600 ${DEPLOY_DIR}/instances/*/env and chown to UID 1000" >&2
	else
		rssh "printf 'AGENTBOX_VERSION=%s\n' '${AGENTBOX_VERSION}' > '${DEPLOY_DIR}/.env'"
		rssh "chmod 600 '${DEPLOY_DIR}'/instances/*/env"
		rssh "install -d -o 1000 -g 1000 -m 0755 '${DEPLOY_DIR}/workspaces'"
	fi
}

# Workspaces must exist and be owned by the image's AGENT_UID before compose binds them: docker
# creates a missing bind-mount directory as root, and the agent then cannot write to it.
prepare_workspaces() {
	local n
	while IFS= read -r n; do
		[ -n "${n}" ] || continue
		rssh "install -d -o 1000 -g 1000 -m 0755 '${DEPLOY_DIR}/workspaces/${n}'"
		rssh "chown 1000:1000 '${DEPLOY_DIR}/instances/${n}/env'"
	done < <(list_instances)
}

# Pull the pinned version, start containers, then read the entrypoint precheck out of the logs.
remote_up() {
	local ts log svc=""
	[ -n "${INSTANCE}" ] && svc=" ${INSTANCE}"
	ts="$(date +%Y%m%d-%H%M%S)"
	log="${LOG_DIR}/${ts}-deploy-${HOST}.log"
	install -d -m 0755 "${LOG_DIR}"
	step "starting containers on ${DEPLOY_HOST} (log: ${log})"
	local cmd="cd '${DEPLOY_DIR}' && docker compose pull${svc} && docker compose up -d${svc} && docker compose ps"
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "plan: ssh ${DEPLOY_HOST} -- ${cmd}" >&2
		return 0
	fi
	local rc=0
	ssh "${SSH_OPTS[@]}" "${DEPLOY_HOST}" "${cmd}" 2>&1 | tee "${log}" || rc=$?
	if [ "${rc}" -ne 0 ]; then
		echo "error: remote compose failed (rc=${rc}); full log at ${log}" >&2
		echo "if the pull was denied, log in on the server once: docker login ghcr.io" >&2
		return 1
	fi
	# The entrypoint lists unset placeholders and exits 2; surface that instead of a bare "started".
	local logs
	logs="$(ssh "${SSH_OPTS[@]}" "${DEPLOY_HOST}" "cd '${DEPLOY_DIR}' && docker compose logs --tail 40${svc}" 2>&1 | tee -a "${log}")"
	if grep -q 'references unset environment variables' <<<"${logs}"; then
		echo "error: a container failed its precheck; see ${log}" >&2
		return 1
	fi
	echo "${log}"
}

do_deploy() {
	sync_host
	[ "${DRY_RUN}" -eq 1 ] || prepare_workspaces
	remote_up
}
```

`main()` 的 `deploy` 分支改为：校验、`print_plan`、然后 `do_deploy`。

`sync_host` 用 `-a` 而不是 `-az`：配置文件很小，压缩没有收益，而 `-z` 在某些 rsync 版本上与 `--delete` 组合时更难排查。`--delete` 只作用于 `instances/`，因为源里就只有这两项。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh 2>&1 | sed -n '/deploy skill/,/template hygiene/p'`
Expected: 21 条全 PASS。

- [ ] **Step 5: 跑完整门禁**

Run: `make check`
Expected: exit 0。

- [ ] **Step 6: 提交**

```bash
git add .claude/skills/deploy/scripts/deploy.sh scripts/test.sh
git commit -m "deploy: push config, derive the remote env and start pinned containers"
```

---

## Task 9: status 动作

**Files:**
- Modify: `.claude/skills/deploy/scripts/deploy.sh`
- Modify: `scripts/test.sh`

**Interfaces:**
- Consumes: Task 8 的 `rssh`。
- Produces: `do_status()`。

- [ ] **Step 1: 写失败的断言**

```bash
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run status h1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'compose ps' <<<"$out" \
	&& ok "status dry-run shows compose ps" || bad "status dry-run shows compose ps" "rc=$rc $out"
out="$(env -u AGENTBOX_DEPLOY_REPO bash "$dp/skill/scripts/deploy.sh" --dry-run status 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "status without a host exits 1" || bad "status without a host exits 1" "rc=$rc"
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `bash scripts/test.sh 2>&1 | grep 'status dry-run'`
Expected: FAIL，`status` 分支目前只打印一行。

- [ ] **Step 3: 实现**

```bash
do_status() {
	rssh "cd '${DEPLOY_DIR}' && docker compose ps && docker compose logs --tail 20"
}
```

`main()` 的 `status` 分支调用它。`status` 不做本地校验也不看 git 状态，它只回答"服务器上现在什么样"。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash scripts/test.sh 2>&1 | sed -n '/deploy skill/,/template hygiene/p'`
Expected: 23 条全 PASS。

- [ ] **Step 5: 跑完整门禁**

Run: `make check`
Expected: exit 0。

- [ ] **Step 6: 提交**

```bash
git add .claude/skills/deploy/scripts/deploy.sh scripts/test.sh
git commit -m "deploy: add a status action for remote container state"
```

---

## Task 10: SKILL.md

**Files:**
- Create: `.claude/skills/deploy/SKILL.md`
- Create: `.claude/skills/deploy/references/deploy-repo.md`

**Interfaces:** 无代码接口。SKILL.md 的 frontmatter `description` 决定这个技能什么时候被触发，写法参照 `remote-build` 与 `new-instance`。

- [ ] **Step 1: 写 SKILL.md**

Create `.claude/skills/deploy/SKILL.md`。frontmatter 的 `name` 必须是 `deploy`，`description` 要覆盖用户可能的说法（发布、上线、部署、推到服务器、publish、deploy、上生产）：

```markdown
---
name: deploy
description: Publish agentbox instances to a remote docker host from the private deploy repository. Use this whenever the user wants to deploy, publish, release, restart or update an agent on a server, or asks what is currently running on a host, including phrasings like "发布到服务器", "上线", "部署一下", "推到生产", "deploy the aliyun agent", "what is running on hk-test". It reads the deploy repo path from the skill's gitignored .env and every host detail from that repo, so no addresses or secrets are typed in chat.
---

# Deploy

`remote-build` is the developer loop; this skill is the release path. Configuration and secrets
live in a separate private repository, one directory per host; images come from GHCR pinned to a
version. The agentbox source tree never reaches the target host.

## Configuration

The deploy repo path lives in `.claude/skills/deploy/.env` (gitignored, template in
`.env.example`). Flags and environment variables override it. If `.env` is missing, do not guess
or ask for a path in chat: point the user at `.env.example` and stop.

Every per-host detail (ssh address, key, proxy, remote directory, target version) lives in the
deploy repo at `hosts/<host>/host.env`. Connection fields stay local; only `AGENTBOX_VERSION` is
derived into the remote `.env`.

## Actions

```bash
.claude/skills/deploy/scripts/deploy.sh plan   <host> [instance]
.claude/skills/deploy/scripts/deploy.sh deploy <host> [instance]
.claude/skills/deploy/scripts/deploy.sh status <host>
```

- Always run `plan` first and show the user its output. It validates every instance's placeholders
  against its env file, refuses a dirty deploy repo, and lists which containers will restart. It
  never connects, so it is safe at any time.
- `deploy` interrupts any session in progress on the containers it restarts. Omitting `instance`
  restarts every instance on that host. Prefer naming one instance.
- Omit nothing else: the target version comes from `host.env`, not from a flag. Upgrading or
  rolling back is an edit to `host.env` followed by a deploy.
- `--force` proceeds despite uncommitted changes in the deploy repo. Say once why that is a bad
  idea and keep the default unless the user insists.

## Reading results

On success the log path is the only thing on stdout; everything else is progress on stderr. Read
the last 40 lines of the log first. A `denied` or `unauthorized` line from the pull means the
server is not logged in to GHCR (`docker login ghcr.io`, a human step). A precheck line naming
unset environment variables means that instance's `env` is incomplete on the server, which
normally cannot happen because `plan` checks it locally first.

Always report which action ran, the host as configured, the version, pass or fail, and the log
path. Never paste the deploy repo's env contents or the full log into the reply.

## Guardrails

- Never write, request, echo or guess a real secret value, and never put a host address in chat.
- Never deploy without showing the user a `plan` first.
- Never sync anything from the agentbox source tree to a target host, and never pull files back.
- The GHCR pull credential is a human step on the server. Do not automate `docker login` and do
  not ask the user for a PAT in chat.
```

- [ ] **Step 2: 写部署仓库参考**

Create `.claude/skills/deploy/references/deploy-repo.md`，内容是部署仓库的结构与每个字段的含义，照 spec 第 4 节写，包含一份 `host.env` 模板（占位值）和一份生产 compose 样例。这是给人第一次建仓库时看的。

- [ ] **Step 3: 跑门禁**

Run: `make check`
Expected: exit 0。`scripts/test.sh` 不检查 SKILL.md 内容，但 `.env.example` 那条地址断言会覆盖到这个技能。

- [ ] **Step 4: 提交**

```bash
git add .claude/skills/deploy/SKILL.md .claude/skills/deploy/references/deploy-repo.md
git commit -m "deploy: document the skill and the deploy repo layout"
```

---

## Task 11: 文档同步

spec 第 11 节列的六处。`test.sh` 不检查这些，靠这个任务收口。

**Files:**
- Modify: `docs/SECRETS.md`
- Modify: `docs/ROADMAP.md`
- Modify: `.claude/skills/new-instance/references/checklist.md`
- Modify: `.claude/skills/new-instance/SKILL.md`
- Modify: `README.md`

- [ ] **Step 1: SECRETS.md 增加部署仓库这一层**

在 §2 占位符机制那张链路图之后，补一段说明真值从哪来。现在的链路图只画到"compose 的 env_file"，要接上部署仓库：

```
部署仓库 hosts/<host>/instances/<name>/env  →  rsync 0600 到服务器  →  compose 的 env_file  →  容器环境变量
```

同时在 §5 的轮换表里补一行：部署仓库里的明文一旦泄露，要轮换该仓库涉及的全部平台密钥与网关 key，并说明 git 历史删不干净、`git rm` 不解决问题。这一段必须写明这是明知代价后的选择，不要写成建议做法。

- [ ] **Step 2: ROADMAP.md 增加验收项**

在 P1 表里加两行。第一行是 Task 1 的闸门：`v*` tag 发布链路首跑，验收是两个多架构镜像在 GHCR 上可被服务器拉取。第二行是本技能：验收是在真实主机上 `plan` 与 `deploy` 各跑通一次，且 `status` 能看到容器 running。

按仓库规矩，这两行在未经真实环境验证前不得写成已确认。

- [ ] **Step 3: new-instance 的交接清单改向部署仓库**

`references/checklist.md` 现在第 1 步是"在 examples/<name>/ 下建 env"。改成：把 `examples/<name>/` 复制到部署仓库的 `hosts/<host>/instances/<name>/`，在那里填真值。第 5 步的工作区属主改为由 deploy 技能在远端创建。第 6、7 步的 `docker network create` 与 `docker compose up` 改为由 deploy 技能执行，人工只需读 `plan` 输出。保留第 2、3、4、8、9 步，它们仍然是人的责任。

- [ ] **Step 4: new-instance 的 SKILL.md 声明 examples 是模板**

在 Step 3 交接那一节前面加一句：`examples/<name>/` 是模板，进 git 且只有 `env.example`；真实实例活在部署仓库里，由 `deploy` 技能投放。

- [ ] **Step 5: README 补一句发布路径**

README 的挂载契约表不动。在讲 `env_file` 那段之后加一句：本地开发用根目录的 compose，发布到服务器走 `deploy` 技能与独立的部署仓库，镜像按版本从 GHCR 拉取。

- [ ] **Step 6: 跑门禁**

Run: `make check`
Expected: exit 0。`contract consistency` 组盯着 README 与 entrypoint 帮助文本的一致性，如果 README 改动碰到了挂载契约表，这一组会红。

- [ ] **Step 7: 提交**

```bash
git add docs/SECRETS.md docs/ROADMAP.md README.md .claude/skills/new-instance/
git commit -m "docs: fold the deploy repo into the secrets flow and the instance handoff"
```

---

## 自查结果

**Spec 覆盖。** spec 十二节逐条对应：第 1 节背景无需实现；第 2 节六条决策分别落在 Task 8（推密钥）、Task 6（git 仓库）、Task 11 Step 1（明文的代价写进文档）、Task 8（GHCR 版本化）、Task 3（多主机）、Task 2（技能住 agentbox）；第 3 节边界落在 Task 11 Step 3 与 4；第 4 节结构落在 Task 3 与 Task 10 Step 2；第 5 节远端布局落在 Task 8；第 6 节接口落在 Task 7、8、9；第 7 节四条护栏分别是 Task 4、Task 6、Task 8（0600 与属主）、Task 8（白名单单向）；第 8 节落在 Task 5，且在那里收紧了 spec 的表述；第 9 节测试项分散在各任务的第一步；第 10 节前置条件是 Task 1；第 11 节改动清单是 Task 11；第 12 节非目标不产生任务。

**与 spec 的一处偏离，已消解。** spec 第 8 节原先要求三处占位符实现输出一致，Task 5 改为只锁 `deploy.sh` 与 `entrypoint.sh` 两处。spec 第 8 节已于 2026-09-07 同步改写，两份文档现在一致，执行者无需再动它。

**占位符扫描。** 计划里没有 TBD、TODO、"类似 Task N"、"加上适当的错误处理"这类空话。所有代码步骤都给了完整可运行的代码。Task 10 Step 2 的参考文档只给了内容要求而没给全文，因为它是纯说明性文档且内容已由 spec 第 4 节确定，执行者照抄即可。

**命名一致性。** 跨任务引用的函数名统一为：`load_host_env`、`list_instances`、`config_placeholders`、`check_instance`、`check_all_instances`、`check_repo_clean`、`print_plan`、`rssh`、`make_rsync_ssh`、`sync_host`、`prepare_workspaces`、`remote_up`、`do_deploy`、`do_status`。全局变量统一为：`REPO`、`HOST`、`INSTANCE`、`HOST_DIR`、`DEPLOY_HOST`、`DEPLOY_KEY`、`DEPLOY_HOST_KEY_ALIAS`、`DEPLOY_SOCKS`、`DEPLOY_DIR`、`AGENTBOX_VERSION`、`SSH_OPTS`、`LOG_DIR`、`FORCE`、`VERBOSE`、`DRY_RUN`。`DP_SRC` 在 Task 5 从 `deploy skill` 组上移到文件顶部常量区。

**一处执行期需要注意的顺序依赖。** Task 3 给 `h1` 写了 `host.env`，Task 2 的第二、三条断言用的是 `h2`，所以 `$dp/other/hosts/h2` 也需要一份 `host.env`。Task 3 Step 4 已写明这一点，执行者到那里补 fixture 即可，不要把它当成回归。
