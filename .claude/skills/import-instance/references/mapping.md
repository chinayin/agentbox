# 映射规则

本页是 `render.py` 行为的人读版；改规则先改代码与 `scripts/test.sh`，再改这里。

## 4.1 `config.toml` 的行级改写

只改 `[projects.agent.options]` 与 `[projects.agent.options.env]` 两个表里的行，其余原样。值可以是双引号也可以是单引号的 TOML 字符串，两种写法都会被改写，改写后统一落成双引号。三引号（`"""` 或 `'''`）包起来的多行字符串原样透传、不改写，规划表的 red items 里会提醒人手工改写它。

| 源侧写法 | 目标写法 | 值去哪 |
|---|---|---|
| `work_dir = "/data/agents/x"` | `work_dir = "${WORK_DIR}"` | 不进 `env`，compose 提供 |
| `KEY = "${KEY}"` | 不变 | `env` 里沿用源侧 `.env` 的值 |
| `KEY = "literal"` | `KEY = "${KEY}"` | `env` 里 `KEY=literal`，原值；KEY 命中密钥名模式 `(TOKEN\|SECRET\|PASSWORD\|_KEY$\|^KEY_)` 时规划表额外提醒「源侧把密钥写死在 config 里，已抽到 env」 |
| `KUBECONFIG = "/home/agent/.kube/a.yaml:/home/agent/.kube/b.yaml"` | `KUBECONFIG = "/agent/kubeconfig-a.yaml:/agent/kubeconfig-b.yaml"` | 字面值；每个文件产生一条 `:ro` 挂载 |
| `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` 字面值 | `${HTTP_PROXY}` 等 | `env` 里带原值，规划表提醒「目标主机的出网路径可能不同，确认后再保留」 |
| `KEY = """..."""` / `KEY = '''...'''`（多行） | 原样透传，不改写 | red items：多行字符串未改写，需要手工转换 |

`allow_from` / `admin_from` 不在这两个表里，原样保留；规划表提醒 open_id 是「用户 × 应用」的组合，换聊天应用必须重新取值。

`.env` 里有而 `config.toml` 没有引用的键（源侧的 `WORK_DIR` 就是一例）不进目标 `env`，规划表列为「丢弃」。目标 `env` 的键序：先源侧 `.env` 的原有顺序，再追加从 config 抽出来的字面值。

## 4.2 文件型凭据

| 源侧 | 目标挂载 | 配套 |
|---|---|---|
| `KUBECONFIG` 引用的每个文件 | 复制到 `./instances/<name>/kubeconfig-<basename>`（0600），挂 `/agent/kubeconfig-<basename>:ro` | 见 4.1 |
| `$HOME/.ssh/` 下的私钥（无 `.pub` 的同名文件） | 复制到 `./instances/<name>/ssh_key`（0600）；第一把挂 `/agent/ssh_key:ro`，多于一把时规划表列出并只挂第一把 | env 表加 `GIT_SSH_COMMAND = "ssh -i /agent/ssh_key -o IdentitiesOnly=yes"`。`known_hosts` 落 `/state/.ssh/`，`HOME` 可写，首连自动写入，不需要进容器初始化 |
| `$HOME/.gnupg` | 不迁 | 规划表单独列一条：签名密钥若需要，另行按 `docs/TOOLS.md` 的凭据通道提供 |

复制用 rsync 一次拉取，落地即 `chmod 600`；属主对齐 UID 1000 是 `deploy` 在目标主机上做的事，本机不改属主。规划表列出源路径与目标路径。

## 4.3 技能

| 源侧 | 去向 |
|---|---|
| `$HOME/.claude/skills/<x>`（用户级，`npx skills` 安装） | 复制到 `./instances/<name>/claude/.claude/skills/<x>`，compose 加 `./instances/<name>/claude:/etc/claude-code:ro`。`.skill-lock.json` 一并复制，供日后 `npx skills update` |
| `work_dir/.claude/skills/*`、`work_dir/skills/*` | 不动，随工作区 |
| `$HOME/.claude/settings.json`、`$HOME/.claude.json`、会话 | 不迁，state 卷从空开始 |

技能目录里 `grep -l docker` 命中的文件按「运行路径」与「自测脚本」分列：命中 `SKILL.md` 正文视为运行路径，规划表标红；只命中 `test.sh` 视为自测，规划表说明「容器内跑不了这几个自测」。

## 4.4 工具覆盖

源侧每个 CLI 与 `mise.lock` 对照。lock 里工具名是 `backend:owner/name` 形式，与二进制名对不上（`kubectl` 对 `aqua:kubernetes/kubectl`），所以匹配用小写子串，命中多个时全列。输出三列：源侧版本、lock 版本、结论。结论是 `covered`（大版本一致）、`major differs`（lock 里有，大版本不一致）、`not in lock`（子串完全没命中）、`ambiguous`（子串命中了不止一个 lock id：所有候选连同各自的 lock 版本一起列出）四种之一，其中 `not in lock` 与 `ambiguous` 是 red items，处理办法只有两条：进 `mise.toml`（见 `docs/TOOLCHAIN.md` §4）或改技能不依赖它。`docker` 是特例，永远单独判红：结论固定是「容器里没有 docker」（没有 socket，设计如此），不看源侧装的是什么版本，也不去对 lock。

## 4.5 工作区

`work_dir` 若是 git 仓库，规划表给出远端 URL，并写明：`deploy` 创建 `workspaces/<name>/` 并 chown，clone 是操作者在主机上做的人工步骤（需要 git 凭据）。不是 git 仓库时，规划表标注「需要 rsync 一次，属主对齐 UID 1000」，技能本身不做这次 rsync。
