# 多 project、跨实例调用与共享依赖

## 1. 容器边界 = 信任域边界

不是一个 project 一个容器，判据是密钥是否需要隔离：

| 情况 | 放法 |
|---|---|
| 互相调用、共享同一套密钥 | 同容器，一个桥接器带多个 `[[projects]]` |
| 不同密钥集 / 仓库 / 团队 | 不同容器，跨域调用应显式且有摩擦 |

按 project 拆容器的代价：内置的跨 project 调用失效，每个实例常驻一份 agent CLI 内存。

新开信任域用仓库自带的 Claude Code 技能 `.claude/skills/new-instance/SKILL.md`：它复制 `examples/demo/` 生成配置骨架、建工作区目录并打出 compose 片段，不写任何真值。

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

- 表名不带 project 名。`[projects.second.agent]` 会把 agent 放进多余的子表，第二个 project 就没有 agent 配置，cc-connect 启动时会报缺 agent。`scripts/test.sh` 会把模板里的第二段取消注释后校验。
- open_id 是「用户 × 应用」的组合，不同应用下同一人的 open_id 不同，放行名单必须各自取值。填错是 fail closed，只会没人能用。

## 3. 跨 project 调用

cc-connect 自带 `relay send --to <project>`、`send`、`cron`，`relay.visibility = full | summary | none` 控制对端可见的上下文。路由走 data-dir 里的 `run/api.sock`，**同容器开箱可用，跨容器默认不通**。

跨信任域三条路：

| 方式 | 评价 |
|---|---|
| 走聊天平台 | 起步推荐，零新增机制、天然审计、有人在环 |
| 挂对端 `/state/run`，`relay send --data-dir` 指过去 | 单向可控，不需 docker 权限。**协议未公开，未实测** |
| 共享任务目录 + cron | 最土最可控，适合异步批处理 |

排除：挂 docker socket 让 A `docker exec b`。

## 4. 共享依赖按变更频率分三类

| 类型 | 载体 |
|---|---|
| 通用工具链，稳定且所有实例都要 | 镜像层 |
| 团队脚本库 | `/opt/toolkit:ro`，`bin/` 已在 PATH |
| Claude 技能、组织级 CLAUDE.md、托管 settings | `/etc/claude-code:ro`，见 [SKILLS](SKILLS.md) |
| 构建缓存 | `/cache`，每信任域一个 named volume |

一天改三次的放镜像里调试链路太长，一个月不动的挂外面只是多一处漂移源。

## 5. 读别人的工作区

```yaml
volumes:
  - ${WORKSPACES_ROOT}/a:/workspace       # rw，自己的
  - ${WORKSPACES_ROOT}/b:/refs/b:ro       # ro，别人的
```

**交叉挂载只读且单向。** 双向 rw = 两个 agent 同时写一个 git 工作区，`index.lock` 争抢、半提交、互相 revert。要读写别人的仓库走 git（B 推、A pull）。

## 6. 网络与资源

所有 agentbox 容器共用一张宿主级网络 `agentbox`，宿主一次性创建：

```bash
docker network create agentbox
```

compose 里声明为 `external: true`，所以多个 compose 工程（或一个工程下的多个 service）都落在这张网上，彼此用容器名解析。这是有意的：单机跑多套 agentbox 时，跨栈调用和共用旁路服务不必再改网络拓扑。

代价说清楚：**网络层不做信任域隔离。** 隔离靠的是各自独立的 `env_file` 与 state / cache 卷，不是网段。见 [SECRETS §3](SECRETS.md)。

`internal: true` 不能拿来做隔离：它切断的是出站，而容器必须能连聊天平台与模型网关。

资源上限只设 pids：

```yaml
deploy:
  resources:
    limits:
      pids: ${AGENT_PIDS_LIMIT}
```

agent 频繁 fork，失控的 fork 循环拖垮的是宿主而不只是容器，所以 pids 不能省。它必须写在 `deploy.resources.limits` 下：Compose v5 不接受 `pids_limit` 与它并存**且取值不同**（取值相同时并存是允许的）。

内存与 CPU **有意不设上限**。单机常见 2c4g，硬上限会让先撞到的实例被 OOM kill，而 agent 负载本来就是突发式的：先让它们跑起来。代价是一个失控实例能吃光宿主内存，接受这个取舍的前提是同一台机器上的实例都归可信的运维团队管。
