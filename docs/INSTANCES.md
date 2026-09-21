# 实例：信任域、目录、跨实例调用、网络

> 契约。一个实例怎么切、目录里有什么、实例之间怎么通。

## 1. 实例 = 信任域 = 一个目录 = 一个 compose 项目

不是一个 project 一个容器，判据是密钥是否需要隔离：

| 情况 | 放法 |
|---|---|
| 互相调用、共享同一套密钥 | 同容器，一个桥接器带多个 `[[projects]]` |
| 同一套密钥，但要换 agent CLI（pi 镜像）、独立工作区，或一个 project 挂掉不该连累另一个 | 同实例，第二个 service：在实例的 `docker-compose.yaml` 里再写一段 `<<: *agentbox`，共用 `./env`，各自的 config、工作区与卷 |
| 不同密钥集 / 仓库 / 团队 | 新实例（新目录、新 compose 项目），跨域调用应显式且有摩擦 |

按 project 拆容器的代价：内置的跨 project 调用失效，每个容器常驻一份 agent CLI 内存。

实例目录 `instances/<name>/`：

| 文件 | 作用 |
|---|---|
| `docker-compose.yaml` | 从 `examples/demo/docker-compose.yaml` 生成。所有路径相对本目录，compose 项目名取目录名（卷自动带前缀 `<name>_state`）。加固块（`cap_drop`、`no-new-privileges`、`init`、pids 上限、外部网络）在文件内用 YAML 锚点引用，不跨文件继承；`deploy plan` 逐文件断言它完整 |
| `config.toml` | 实例声明，只含 `${占位符}` |
| `env` | 环境变量型凭据，0600 |
| `home/`（可选） | 文件型凭据，照 `~` 的结构摆（[CREDENTIALS](CREDENTIALS.md) §2） |
| `skills-lock.json`（可选） | 技能清单（[SKILLS](SKILLS.md)） |
| `workspace/`（可选） | 工作区里由运维声明、agent 只读不改的文件：工作区的 `CLAUDE.md`、subagent 定义、项目级 settings。`deploy` 每次直接覆盖进工作区（不带 `--delete`，agent 自己的文件不动），从仓库删掉的文件要手工清；不进服务器的 `instances/` 镜像 |
| `workspace-init/`（可选） | 工作区一次性种子：agent 要能改写、因而不能 `:ro` 挂的文件（[CREDENTIALS](CREDENTIALS.md) §2）。已存在的文件永不覆盖，所以运维要改的提示词不得放这里 |

`deploy` 在服务器上进入该目录运行 compose，每个实例独立 `pull`/`up`。搬迁一个实例只需带走这个目录、它的工作区与两个卷。

新开信任域用 `.claude/skills/new-instance/SKILL.md`：复制 `examples/demo/` 生成骨架、建工作区目录、打出 compose 片段，不写任何真值。已有裸机 cc-connect 要换成容器的，用 `.claude/skills/import-instance/SKILL.md`：只读读取源主机，按挂载契约写进部署仓库，上线仍走 `deploy`。

## 2. 同信任域加 project：只改配置

```toml
[[projects]]
name = "second"
admin_from = "${ADMIN_FROM}"

[projects.agent]
type = "claudecode"

[projects.agent.options]
work_dir = "/workspace/second"
mode = "acceptEdits"

[[projects.platforms]]
type = "feishu"

[projects.platforms.options]
app_id = "${FEISHU_APP_ID_SECOND}"
app_secret = "${FEISHU_APP_SECRET_SECOND}"
allow_from = "${ALLOW_FROM_SECOND}"
```

`examples/demo/config.toml` 有可直接取消注释的模板。两个坑：

- 表名不带 project 名。`[projects.second.agent]` 会把 agent 放进多余的子表，cc-connect 启动时报缺 agent。`scripts/test.sh` 会把模板里的第二段取消注释后校验。
- open_id 是「用户 × 应用」的组合，不同应用下同一人的 open_id 不同，放行名单必须各自取值。填错是 fail closed。 应用在飞书后台要开的权限、事件、回调见 [CHANNELS](CHANNELS.md)。

## 3. 跨 project 调用

cc-connect 自带 `relay send --to <project>`、`send`、`cron`，`relay.visibility = full | summary | none` 控制对端可见的上下文。路由走 data-dir 里的 `run/api.sock`，**同容器开箱可用，跨容器不通**：relay 的目标必须是同一进程里的 project（源码判定，未实测，[ROADMAP](ROADMAP.md) 第 2 行）。

跨信任域两条路：走聊天平台（起步推荐，零新增机制、天然审计、有人在环），或共享任务目录 + cron（最土最可控，适合异步批处理）。排除挂 docker socket 让 A `docker exec b`。几个 bot 在一个群里协作的设计稿见 `docs/design/MULTI_CLOUD.md`（未实现）。

## 4. 共享依赖按变更频率分三类

| 类型 | 载体 |
|---|---|
| 通用工具链，稳定且所有实例都要 | 镜像层 |
| 团队脚本库 | `/opt/toolkit:ro`，`bin/` 已在 PATH |
| 被托管仓库自建的二进制 | 仓库 `make build` 落 `/workspace/bin`，已在 PATH 末尾，技能按名字直接调用 |
| Claude 技能、组织级 CLAUDE.md、托管 settings | `/etc/claude-code:ro`，见 [SKILLS](SKILLS.md) |
| 构建缓存 | `/cache`，每信任域一个 named volume |

一天改三次的放镜像里调试链路太长，一个月不动的挂外面只是多一处漂移源。

## 5. 读别人的工作区

```yaml
volumes:
  - ${WORKSPACES_ROOT}/a:/workspace       # rw，自己的
  - ${WORKSPACES_ROOT}/b:/refs/b:ro       # ro，别人的
```

**交叉挂载只读且单向。** 双向 rw 等于两个 agent 同时写一个 git 工作区。要读写别人的仓库走 git。

## 6. 网络与资源

所有 agentbox 容器共用一张宿主级网络 `agentbox`，宿主一次性 `docker network create agentbox`，每个实例的 compose 声明 `external: true`。docker 内置 DNS 按网络划分，任何实例都能用容器名 `agentbox-<name>` 解析到另一个；共用旁路服务（模型网关、内网 git）加入这张网即可。网络互通不等于 agent 互调（§3）。

**网络层不做信任域隔离**，隔离靠各自独立的 `env_file` 与卷（[CREDENTIALS](CREDENTIALS.md) §4）。`internal: true` 不能拿来做隔离：它切断的是出站。

资源上限只设 pids，写在 `deploy.resources.limits` 下（Compose v5 不接受 `pids_limit` 与它并存且取值不同）：

```yaml
deploy:
  resources:
    limits:
      pids: 512
```

实例模板写死 512，`deploy plan` 按字面断言这一行；只有本地开发用的根目录 compose 才通过 `AGENT_PIDS_LIMIT` 取值。agent 频繁 fork，失控的 fork 循环拖垮的是宿主，所以 pids 不能省。内存与 CPU **有意不设上限**：单机常见 2c4g，硬上限会让先撞到的实例被 OOM kill，而 agent 负载是突发式的。代价是一个失控实例能吃光宿主内存，前提是同一台机器上的实例都归可信的运维团队管。
