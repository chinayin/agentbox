# 技能安装与迁移

技能本体不需要"迁移"，`npx skills` 按清单重装即可。真正要搬的是配置与凭据，通常只是几个环境变量。

## 1. 三种落法

| 落法 | 位置 | 适用 |
|---|---|---|
| 清单驱动（默认） | 挂 `/agent/skill-lock.json`，entrypoint 首启按清单 `npx skills add -g` 装进 `/state/.claude/skills` | 用户级技能的常规落法。实例只带一份清单，技能本体不进配置仓库 |
| 托管层 | 宿主目录 `:ro` 挂到 `/etc/claude-code` | 组织级策略：`managed-settings.json`、`CLAUDE.md`、`managed-mcp.json`。技能也认（`.claude/skills/<name>/`），但那条路 `npx skills` 不认，只用于必须由宿主锁死、不允许 agent 自行更新的技能 |
| 进工作区 | 仓库自带 `.claude/skills/` | 只属于这个项目的技能，随代码版本化 |

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

`npx skills` 维护 `.skill-lock.json`（global 作用域下在 `~/.agents/` 里），每条含 `source`、`skillPath`、内容哈希。备份或迁移只需这一个文件——它就是挂给容器的 `/agent/skill-lock.json`，放进部署仓库的实例目录随配置版本化。entrypoint 只读它的 `skills.<name>.source`，`sourceUrl` 作为回退。

技能是会被执行的代码，`update` 拉的是上游 HEAD。清单里记的是仓库而不是 commit，所以更新时机由人决定：不要让 agent 自己定期 update。

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
