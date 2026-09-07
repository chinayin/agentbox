# 技能安装与迁移

技能本体不需要"迁移"，`npx skills` 按清单重装即可。真正要搬的是配置与凭据，通常只是几个环境变量。

## 1. 三种落法

| 落法 | 位置 | 适用 |
|---|---|---|
| 托管层 | 宿主目录 `:ro` 挂到 `/etc/claude-code`，技能放 `.claude/skills/<name>/` | 团队共享、由宿主统一管理的技能；改完重启容器即生效，重建 state 卷不丢 |
| 装进 state | `/state/.claude/skills`，容器内 `npx skills add -g` | 第三方技能临时试用；重建 state 卷即丢，靠 §3 的清单复现 |
| 进工作区 | 仓库自带 `.claude/skills/` | 只属于这个项目的技能，随代码版本化 |

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

`npx skills` 维护 `.skill-lock.json`，每条含 `source`、`skillPath`、内容哈希。备份或迁移只需这一个文件，建议放进实例目录随配置版本化。

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
