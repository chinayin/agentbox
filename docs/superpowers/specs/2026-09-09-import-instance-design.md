# 导入技能设计：把裸机 cc-connect 实例迁进 agentbox

日期：2026-09-09。状态：待评审。

从一台已经在跑的实体机上反向导入一个 cc-connect 实例，产出 agentbox 的实例骨架和一份迁移规划。本文只记设计与取舍，落地待办进 `ROADMAP.md`。

## 1. 要解决的问题

现有三个技能覆盖的是「从零开始」：`new-instance` 从模板造空壳，`deploy` 把部署仓库推到主机，`remote-build` 造镜像。没有一条路径处理「已经有一台裸机在跑、要换成容器」。这次的源是一台北京 ECS：cc-connect 与 Claude Code 用 npm 全局安装，以 `agent` 用户跑在 systemd user 单元里，实例目录 `/data/agents/<name>/.cc-connect/` 下有 `config.toml` 和 `.env`，家目录里散落着 kubeconfig、git 私钥、用户级技能。

人工迁一次可以，但每台机器的散落位置都不一样，人肉对照挂载契约表既慢又漏。目标是一条命令读出源侧的全部依赖，逐项映射到挂载契约，写出骨架，剩下只有「填密钥」这一步留给人。

## 2. 已定决策

| # | 决策 | 理由 |
|---|---|---|
| 1 | 对源主机只读 | 源实例在迁移期间继续服务；技能不停它、不改它、不写它 |
| 2 | 输出写进部署仓库 `hosts/<host>/instances/<name>/`，上线走 `deploy` | 不另造第二条上线路径；`plan` 的占位符校验和脏仓库检查免费获得 |
| 3 | 技能不复制任何密钥值 | 与 `new-instance` 同一条红线；`.env` 只读键名，密钥值一律 `xxxx` |
| 4 | 非密钥字面值原样带过去 | 模型名、代理、路径这类 S2 值抄错比抄漏更常见，脚本抄比人抄可靠 |
| 5 | 源侧 `config.toml` 只做行级改写，不重排 | 表结构、注释、顺序都是源侧运维的知识，保留它们，diff 才可读 |
| 6 | 源可以是本地目录 | 让 `test.sh` 离线跑完全部改写逻辑；也覆盖「先 scp 下来再看」的用法 |

## 3. 源侧读什么

一次 ssh 执行一段只读的采集脚本，输出纯文本清单。采集项与用途：

| 采集 | 用途 | 读到什么程度 |
|---|---|---|
| `<dir>/config.toml` 全文 | 改写成 agentbox 版 | 全文。它只含占位符与 S2 字面值；若发现形如 `sk-`/`cli_` 开头的长串则报错退出，不落盘 |
| `<dir>/.env` | 生成目标 `env` 的键清单 | 只读 `=` 左边的键名 |
| systemd user 单元 | 确认启动方式、日志位置、额外 `Environment=` | 只读键名与路径 |
| `$HOME/.kube/*`、`$HOME/.ssh/*` | 文件型凭据的挂载清单 | 只读文件名与大小 |
| `$HOME/.claude/skills/*`、`$HOME/.agents/.skill-lock.json` | 托管层技能清单 | 目录名；lock 里的 `source` 与 `skillPath` |
| `work_dir` 下 `.claude/skills/*`、`skills/*` | 判断哪些技能随工作区走 | 目录名；`grep -l docker` 统计运行路径是否碰 docker |
| `work_dir` 的 git 远端 | 工作区如何重建 | URL，去掉 `user:pass@` |
| 一组常见 CLI 的 `command -v` 与版本 | 工具覆盖对照 | 名字、路径、版本首行 |
| `id` 与 `$HOME` | UID 对齐提示 | 数字 |

采集脚本里没有 `cat $HOME/.ssh/*`、没有 `/proc/*/environ`、没有 `.env` 的值。这不是靠自觉，`test.sh` 会 grep 脚本源文件断言这些模式不存在。

## 4. 映射规则

### 4.1 `config.toml` 的行级改写

只改 `[projects.agent.options]` 与 `[projects.agent.options.env]` 两个表里的行，其余原样。

| 源侧写法 | 目标写法 | 值去哪 |
|---|---|---|
| `work_dir = "/data/agents/x"` | `work_dir = "${WORK_DIR}"` | 不进 `env`，compose 提供 |
| `KEY = "${KEY}"` | 不变 | `env` 里 `KEY=xxxx` |
| `KEY = "literal"`，KEY 命中密钥名模式 `(TOKEN\|SECRET\|PASSWORD\|_KEY$\|^KEY_)` | `KEY = "${KEY}"` | `env` 里 `KEY=xxxx`，规划表标红「源侧把密钥写死在 config 里」 |
| `KEY = "literal"`，其余 | `KEY = "${KEY}"` | `env` 里 `KEY=literal` |
| `KUBECONFIG = "/home/agent/.kube/a.yaml:/home/agent/.kube/b.yaml"` | `KUBECONFIG = "/agent/kubeconfig-a.yaml:/agent/kubeconfig-b.yaml"` | 字面值；每个文件产生一条 `:ro` 挂载 |
| `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` 字面值 | `${HTTP_PROXY}` 等 | `env` 里带原值，规划表提醒「目标主机的出网路径可能不同，确认后再保留」 |

`allow_from` / `admin_from` 不在这两个表里，原样保留；规划表提醒 open_id 是「用户 × 应用」的组合，换聊天应用必须重新取值。

`.env` 里有而 `config.toml` 没有引用的键（源侧的 `WORK_DIR` 就是一例）不进目标 `env`，规划表列为「丢弃」。

### 4.2 文件型凭据

| 源侧 | 目标挂载 | 配套 |
|---|---|---|
| `KUBECONFIG` 引用的每个文件 | `./instances/<name>/kubeconfig-<basename>:/agent/kubeconfig-<basename>:ro` | 见 4.1 |
| `$HOME/.ssh/` 下的私钥（无 `.pub` 的同名文件） | 第一把挂 `/agent/ssh_key:ro`，多于一把时规划表列出并只挂第一把 | env 表加 `GIT_SSH_COMMAND = "ssh -i /agent/ssh_key -o IdentitiesOnly=yes"`。`known_hosts` 落 `/state/.ssh/`，`HOME` 可写，首连自动写入，不需要进容器初始化 |
| `$HOME/.gnupg` | 不迁 | 规划表说明：签名密钥若需要，另行按 `docs/TOOLS.md` 通道提供 |

凭据文件本身不复制，只在规划表里给出源路径和目标路径，附 `chmod 600` 与属主 UID 提醒。

### 4.3 技能

| 源侧 | 去向 |
|---|---|
| `$HOME/.claude/skills/<x>`（用户级，`npx skills` 安装） | 复制到 `./instances/<name>/claude/.claude/skills/<x>`，compose 加 `./instances/<name>/claude:/etc/claude-code:ro`。技能是代码不是密钥，复制在决策 3 之外；`.skill-lock.json` 一并复制，供日后 `npx skills update` |
| `work_dir/.claude/skills/*`、`work_dir/skills/*` | 不动，随工作区 |
| `$HOME/.claude/settings.json`、`$HOME/.claude.json`、会话 | 不迁，state 卷从空开始 |

技能目录里 `grep -l docker` 命中的文件按「运行路径」与「自测脚本」分列：命中 `SKILL.md` 正文视为运行路径，规划表标红；只命中 `test.sh` 视为自测，规划表说明「容器内跑不了这几个自测」。

### 4.4 工具覆盖

源侧每个 CLI 与 `mise.lock` 对照。lock 里工具名是 `backend:owner/name` 形式，与二进制名对不上（`kubectl` 对 `aqua:kubernetes/kubectl`），所以匹配用小写子串，命中多个时全列。输出三列：源侧版本、lock 版本、结论（`covered` / `major differs` / `not in lock`）。`not in lock` 是规划表的红项，处理办法只有两条：进 `mise.toml`（见 `docs/TOOLCHAIN.md` §4）或改技能不依赖它。

### 4.5 工作区

`work_dir` 若是 git 仓库，规划表给出远端 URL，并写明：`deploy` 创建 `workspaces/<name>/` 并 chown，clone 是操作者在主机上做的人工步骤（需要 git 凭据）。不是 git 仓库时，规划表标注「需要 rsync 一次，属主对齐 UID 1000」，技能本身不做这次 rsync。

## 5. 技能接口

```
import-instance.sh plan   <source-dir> [--host <host> --name <name>]
import-instance.sh import <source-dir>  --host <host> --name <name>
```

- `<source-dir>` 是源实例目录，即含 `config.toml` 与 `.env` 的那个目录。默认它是源主机上的路径，配合技能 `.env` 里的连接信息读取；加 `--local` 则同一个路径参数指向本地目录，不建立任何连接。
- `import` 复制用户级技能目录时用一次只读的 rsync 拉取（`--local` 时是本地 cp），这是技能对源主机除采集脚本之外唯一的一次访问。
- `plan` 只打规划表到 stdout，不写文件。远程形式会连源主机一次（只读）。
- `import` 先跑 `plan`，再写 `hosts/<host>/instances/<name>/{config.toml,env}` 与 `claude/`，最后把 compose service 片段打到 stdout。目标目录已存在则 exit 1，不覆盖。
- 部署仓库路径与 `deploy` 共用 `AGENTBOX_DEPLOY_REPO`：flag `--repo` > 环境变量 > `.claude/skills/deploy/.env`。不另起一个变量。
- 源主机连接信息放 `.claude/skills/import-instance/.env`（gitignored，`.env.example` 入仓）：`AGENTBOX_IMPORT_SOURCE`、`AGENTBOX_IMPORT_KEY`、`AGENTBOX_IMPORT_SOCKS`、`AGENTBOX_IMPORT_HOST_KEY_ALIAS`，形状与 `remote-build` 一致。
- `--dry-run` 打出将执行的 ssh 与将写的文件路径，不连接、不写。

规划表是给人读的纯文本，分五段：产物映射、字面值改写、文件型凭据、技能、工具覆盖；末尾一段「红项」汇总所有需要人判断的条目。stdout 只有规划表和 compose 片段，进度与告警走 stderr，遵守 `gox-code-rules:shell`。

## 6. 与 `new-instance` 的分工

两者都产出 `config.toml` + `env` + compose 片段，差别在输入：`new-instance` 输入是意图（叫什么、用哪个 agent、挂哪些文件），从 `examples/demo` 模板出发；`import-instance` 输入是现状，从源侧 `config.toml` 出发。前者写进 `examples/`（模板，入 git），后者写进部署仓库（真值目录，密钥值为 `xxxx` 待填）。

不合并成一个脚本：模板派生与现状改写共享的只有「打 compose 片段」这一小段，合并换来的是双倍 flag 和两套互斥的前置检查。compose 片段格式两处各写一份，`test.sh` 对两份输出做同一组结构断言（service 名、volumes、`env_file`、GHCR 镜像形式），漂移会红。

## 7. 护栏

1. **源侧只读。** 采集脚本没有任何写操作；`test.sh` 对脚本源文件断言不含 `>`、`tee`、`rm`、`chmod`、`systemctl`（`--help` 的 heredoc 除外，用行首标记跳过）。
2. **密钥不落盘不上屏。** `.env` 只取键名；`config.toml` 若含形如密钥的长串直接 exit 1 并指出行号，不落盘；`-v` 输出同样过这条检查。`test.sh` 用含假密钥的 fixture 断言。
3. **不覆盖。** 目标实例目录已存在 exit 1。
4. **不碰 compose。** 片段只打 stdout，`hosts/<host>/docker-compose.yaml` 仍由人维护，与 `deploy` 文档一致。
5. **地址不进仓库。** `.env.example` 只放 `xxxx` 形式，`test.sh` 沿用 `deploy` 组那条「无真实 IP」断言。

## 8. 测试

`scripts/test.sh` 新增 `import-instance skill` 组，fixture 是临时目录里的假源实例（`config.toml` 含占位符、密钥名字面值、`KUBECONFIG` 双路径、代理三件、`work_dir` 绝对路径；`.env` 含若干键和一个多余的 `WORK_DIR`；家目录里有假 kubeconfig、一对 ssh key、两个用户级技能目录，其中一个 `test.sh` 提到 docker）：

- `--help` exit 0
- `--local` 的 `plan` 不建立网络连接（给一个不可用的 SOCKS 仍成功）
- 部署仓库路径三级覆盖与 `deploy` 一致
- `work_dir` 改成 `${WORK_DIR}`；密钥名字面值改占位符且 `env` 里为 `xxxx`；非密钥字面值改占位符且 `env` 里带原值；`KUBECONFIG` 改成两个 `/agent/` 路径且片段里有两条 `:ro` 挂载
- 源侧表结构与注释行保留（改写前后非目标表的行逐行相同）
- `.env` 里多余的 `WORK_DIR` 不进目标 `env`，规划表列为丢弃
- config 里出现 `sk-` 长串时 exit 1 且不产生文件
- 目标目录已存在 exit 1
- 规划表红项含 `bypassPermissions`、`not in lock`、docker 自测三类
- compose 片段与 `new-instance` 的片段通过同一组结构断言
- 采集脚本源文件不含写操作模式；`.env.example` 无真实 IP；技能 `.env` 被 `.gitignore` 覆盖

端到端不在 `make check` 里：在构建机上用 `deploy plan` / `deploy` / `status` 跑通，网关 curl 按 `docs/TOOLS.md` §3a，飞书发一条消息拿回复，`docker inspect` 读到 `PidsLimit` 与 `CapDrop`。

## 9. 首次使用：litellm-gateway 实例

这次的具体落点，也是 `ROADMAP` 第 4、5 项的收口：

1. 本机新建私有部署仓库 `agentbox-deploy`，第一个 host 是构建机，`DEPLOY_DIR=/data/agentbox-demo`，`AGENTBOX_VERSION=0.2.0`，镜像 `ghcr.io/chinayin/agentbox`。
2. `import-instance import /data/agents/litellm-gateway/.cc-connect --host hk-build --name litellm-gateway`。
3. 人工：飞书用 demo 应用的 id / secret，`allow_from` / `admin_from` 换成该应用下的 open_id；模型网关地址与 token 填入；代理三件在构建机上清空或按需保留；dev kubeconfig 放到位并 `chmod 600`；把 compose 片段贴进 `hosts/hk-build/docker-compose.yaml`；提交。
4. `deploy plan hk-build litellm-gateway`，看输出；`deploy deploy hk-build litellm-gateway`；`status`。
5. 在构建机上 clone 工作区仓库到 `workspaces/litellm-gateway/`，属主 1000。
6. 验收见 §8 末段。

源 ECS 上的 systemd 实例全程不停。同一个飞书应用不能有两个 cc-connect 消费者，所以 demo 用 demo 应用，源实例继续用它自己的。

## 10. 需要同步改动的文件

| 文件 | 改动 |
|---|---|
| `.claude/skills/import-instance/SKILL.md`、`.env.example`、`scripts/import-instance.sh`、`references/mapping.md` | 新增 |
| `scripts/test.sh` | 新增 `import-instance skill` 组；compose 片段结构断言同时覆盖 `new-instance` |
| `docs/MULTI_PROJECT.md` §1 | 「新开信任域用 new-instance」旁加一句「从裸机迁入用 import-instance」 |
| `README.md` 开发一节 | 技能列表加一行 |
| `docs/ROADMAP.md` | 第 4、5 项验收改为由本次 demo 收口；新增「import-instance 真实源首跑」一项 |
| `.claude/skills/new-instance/SKILL.md` | 开头加一句边界：已有裸机实例走 import-instance |

`.gitignore` 的 `.claude/skills/*/.env` 已覆盖新技能。

## 11. 非目标

- 不迁会话历史与 `~/.claude.json`。state 卷从空开始，这是 `ARCHITECTURE.md` §3 对会话状态的生命周期定义。
- 不复制任何密钥值，不停源实例，不写源主机。
- 不迁 LiteLLM 网关本身，它在 k8s 上。
- 不处理同一主机上无关的容器栈。
- 不生成 `docker-compose.yaml`，只打片段。
- 不做 `npx skills` 重装，直接复制技能目录；`.skill-lock.json` 一并带走，日后更新走 `npx skills update`。
