# 技能安装与迁移

技能本体不需要"迁移"，`npx skills` 按清单重装即可。真正要搬的是配置与凭据，通常只是几个环境变量。

## 1. 三种落法

| 落法 | 位置 | 适用 |
|---|---|---|
| 清单驱动（默认） | 挂 `/agent/skills-lock.json`，entrypoint 首启按清单 `npx skills add -g` 装进 `/state/.claude/skills` | 用户级技能的常规落法。实例只带一份清单，技能本体不进配置仓库 |
| 预装（镜像自带） | 镜像内 `/etc/agentbox/skills-lock.json`，格式与上一行同，entrypoint 先读它再读实例那份 | 每个实例都该有的通用技能。同名以实例清单为准；**没有「取消某条预装」的写法**，所以预装只放与实例无关的能力 |
| 托管层 | 宿主目录 `:ro` 挂到 `/etc/claude-code` | 组织级策略：`managed-settings.json`、`CLAUDE.md`、`managed-mcp.json`。技能也认（`.claude/skills/<name>/`），但那条路 `npx skills` 不认，只用于必须由宿主锁死、不允许 agent 自行更新的技能 |
| 进工作区 | 仓库自带 `.claude/skills/` | 只属于这个项目的技能，随代码版本化 |

## 1b. 清单是 `npx skills` 自己的文件，不是 agentbox 的格式

`npx skills add` 装完会写一份 lock，两个作用域两份：

| 作用域 | 文件 | 版本 | 技能落点 |
|---|---|---|---|
| global（`-g`） | `~/.agents/.skill-lock.json` | 3 | `~/.claude/skills/<name>` |
| project | `<项目>/skills-lock.json` | 1 | `<项目>/.claude/skills/<name>` |

挂给容器的就是这种文件，**原样用，不转换**：entrypoint 只读 `skills.<name>.source`（回退 `sourceUrl`），两份都有这个字段。要加一个技能，在任意空目录 `npx skills add <owner/repo> -s <name> -a claude-code -y`，把生成的 `skills-lock.json` 提交进部署仓库即可，不用手写 JSON。

**为什么不用官方的 `npx skills experimental_install`**（它正是「按这份 lock 还原」那个命令）：2026-09-11 实测，它把技能写进 `<项目>/.agents/skills/<name>` 却不建 `.claude/skills/` 那一份，Claude Code 看不见；配套的 `experimental_sync` 只扫 node_modules，对 GitHub 源的技能报 `No SKILL.md files found in node_modules`。所以装用 `skills add`。等上游把 `experimental_install` 补全，entrypoint 里那个循环可以直接换成它一条命令。

**两个镜像共用这条路,装的位置不同。** entrypoint 按镜像里有哪个 agent CLI 决定,`npx skills` 自己知道每个 agent 读哪里(2026-09-11 实测):

| 镜像 | 检测到 | `-a` 取值 | 技能落点(global) |
|---|---|---|---|
| `agentbox:<版本>` | `claude` | `claude-code` | `/state/.claude/skills/<name>` |
| `agentbox:<版本>-pi` | `pi` | `pi` | `/state/.pi/agent/skills/<name>` |

两个都没有就只告警不安装。注意 pi 的 global 落点是 `.pi/agent/skills`,project 作用域才是 `.pi/skills`,别记混。pi 是否真的从这个目录加载技能尚未端到端验证,见 [ROADMAP](ROADMAP.md) 第 7 行。

**为什么默认是清单而不是把技能挂进去。** `npx skills` 只认两个作用域：project（cwd 的 `.claude/skills`）与 global（`~/.agents/.skill-lock.json` + `~/.claude/skills`）。`/etc/claude-code` 不在其中——挂在那儿的技能，`skills list` 看不见、`skills update` 更新不了，只能靠外部脚本模拟一个 HOME 去伺候它。而 `HOME=/state`，global 作用域天然就落在 state 卷里：装一次持久有效，重启不联网（entrypoint 按目录名跳过已装的），更新就是容器内一句 `npx skills update -g`。2026-09-11 实测：容器内 `npx skills add <src> -g -s <name> -a claude-code -y` 正常装进 `/state/.claude/skills/<name>`（实体目录，非软链），lock 落 `/state/.agents/.skill-lock.json`。

清单缺失、npx 不可用、单条安装失败都只 `Warning:` 不中断启动——技能没装上，agent 仍然应该能收消息。清单本身解析不了同样只告警。

`/opt/toolkit` 只是脚本库（`bin/` 进 PATH），Claude Code 不会从那里发现 `SKILL.md`。

**为什么是 `/etc/claude-code` 而不是把宿主目录挂进 `/state/.claude/skills`。** 那是 Claude Code 在 Linux 上的官方托管目录：只读、优先级最高、不需要任何链接或同步逻辑。反过来在 state 卷内部嵌套挂载有一个坑：docker 会以 root 创建嵌套挂载点，`/state/.claude` 变成 root 属主，agent 用户随即写不进会话状态。托管层目录里 `<name>` 可以是软链，Claude Code 会跟随并去重。

## 1a. 托管层还能放什么

| 文件 | 作用 | 备注 |
|---|---|---|
| `managed-settings.json` | 权限规则、deny 列表、env、hooks，agent 与项目配置都改不掉 | 团队各自的部分可拆到 `managed-settings.d/*.json` |
| `CLAUDE.md` | 组织级指令，在用户级与项目级之前加载，不可被 `claudeMdExcludes` 排除 | 也可以写进 settings 的 `claudeMd` 键 |
| `managed-mcp.json` | 组织级 MCP 服务器 | 项目级 MCP 放工作区 `.mcp.json` |
| `.claude/skills/<name>/SKILL.md` | 技能 | 见上表 |

两条硬规则：

- 托管 JSON 不可读或解析失败时，Claude Code 会在启动时直接退出并提示联系管理员，容器日志可见。宿主文件权限要 `0644`，属主任意。
- 技能目录必须含 `SKILL.md`，否则静默不加载。

可变状态（`~/.claude.json`、`~/.claude/settings.json`、会话、自动记忆）继续留在 state 卷，不要挂只读。

## 2. 安装与四个坑

```bash
npx --yes skills add <owner/repo> -g -s <skill-name> -a claude-code -y
```

| 坑 | 处理 |
|---|---|
| agent 名写 `claude` 报 `Invalid agents` | 照抄 `claude-code` |
| 多条 add 串在一个脚本里只有第一条生效，后面静默中断 | 一条一条执行 |
| 有的环境是软链、有的是复制 | 装完 `ls` 确认实体位置 |
| 大仓库不慢 | 浅克隆，不必配代理 |

## 3. 清单

格式与两个作用域见 §1b。备份或迁移只需这一个文件——它就是挂给容器的 `/agent/skills-lock.json`，放进部署仓库的实例目录随配置版本化。

技能是会被执行的代码，`update` 拉的是上游 HEAD。清单里记的是仓库而不是 commit，所以更新时机由人决定：不要让 agent 自己定期 update。

## 3a. 装不上会怎样

单条失败、npx 缺失、清单解析不了，都只 `Warning:` 不中断启动。启动尾部还会补一条 `Warning: N of M skills in the manifest are not installed`，并在 `/state/.agents/.agentbox-skills-missing` 留一个标记文件——`deploy status` 看的是 `docker compose logs --tail 40`，跑几天之后启动日志早被刷走了，标记文件是任何时候都能 `docker exec cat` 到的那份真相。全部装上时标记文件会被删掉。

## 3b. 需要代理时，变量放 `env_file`

entrypoint 在 cc-connect **之前**跑，所以 `config.toml` 的 `[projects.agent.options.env]` 里那套代理变量对它无效——那是 cc-connect 注入给 agent 子进程的。装技能要走代理，`HTTPS_PROXY` / `https_proxy` 必须写进 `env_file`（容器级环境变量）。实测两段都认：npm 取 `skills` 包（`registry.npmjs.org`）和 `skills` 内部 `git clone` 技能仓库，给个不通的代理两段都会失败。

`AGENTBOX_PROFILE=cn` 会把 npm registry 指到 npmmirror（`apply_defaults` 在安装之前跑），**npm 那一段免代理**；技能内容是从 GitHub clone 的，没有镜像，那一段仍需代理。`NO_PROXY` 照 [ARCHITECTURE §5](ARCHITECTURE.md) 同时写 CIDR 与单 IP。

## 4. 凭据

技能凭据与桥接器凭据同一条路：`env_file` 真值 → `config.toml` 的 `[projects.agent.options.env]` 写 `${占位符}` → 桥接器注入 agent 子进程。各工具认的变量名与文件位置见 [TOOLS](TOOLS.md)。不能放 shell rc 文件（见 [SECRETS §2](SECRETS.md)）。改完重建容器，日志里不能有 `placeholder references unset variable`。

## 5. 三套目录共存

托管层 `/etc/claude-code/.claude/skills/`、用户级 `/state/.claude/skills/`（`npx skills add -g`）与项目级 `/workspace/.claude/skills/`（随仓库）同时加载，同一目标只加载一次。托管层由宿主管理，用户级走 `npx skills update`，项目级跟仓库。

## 6. 新增技能 SOP

1. 开发机上跑通。
2. 从 `.skill-lock.json` 查 `source` 与 `skillPath`。
3. `grep` 它的 `*.sh` 与 `SKILL.md`，列出依赖的 CLI 与凭据。缺 CLI 的：通用且可锁定的加进 `mise.toml`（见 [TOOLCHAIN §4](TOOLCHAIN.md)），一次性的脚本挂 `/opt/toolkit`。
4. 按 §1 选落法安装，一条一条。
5. 凭据按 §4 配好，重建容器。
6. 跑技能自带 `test.sh`。
