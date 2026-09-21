# 多云运维 agent：主 bot 调度专才 bot

> 状态：设计稿，未实现。本文描述的拓扑没有在真实环境跑过，标「源码判定」的结论只来自读源码。不要把这里的内容当作现状引用；实现一段就把契约部分挪进正文文档。

目标：在一个飞书群里放一个「云管家」主 bot，人只问它；它判断问题涉及哪家云，去问对应的专才 bot（阿里云、AWS、火山引擎），汇总后回人。专才各自持有自己那家云的凭据，主 bot 一份云凭据都没有。

这份文档回答三件事：这个形态在架构上怎么成立、用 agentbox 的哪两种拓扑能落地、每种拓扑到哪一步是已验证的。**本文所有「源码判定」均指阅读 cc-connect `main` 分支（2026-09-10，commit 757b4df）得出，不等于真实环境跑通；未跑通的项目列在 [ROADMAP](../ROADMAP.md)。**

## 1. 形态

```
人 ──@云管家──► 主 bot（零云凭据）
                  │  并行问一到三个专才
                  ▼
      阿里云 bot      AWS bot      火山 bot        各持自己的 AK
                  │  只回给主 bot
                  ▼
                主 bot 汇总、标注出处、回人
```

这是 orchestrator-worker：worker 之间不说话，只跟 lead 说。星型拓扑把 bot 互相唤醒的跳数结构性封死在 1，不需要频率闸就没有死循环。

参照物是 xAI 2026-08 发布的 Grok Bot：一个群里 2 到 6 个常驻 bot，可以 @ 指定某个，bot 之间走产品内部的异步消息，共享一台 VM 的文件与登录态，各自保留专属记忆。它闭源、只能用 xAI 模型、不能自托管。开源里在飞书群内做到「bot 互 @ 且带防环」的是 OpenClaw（`allowBots` + 同一对 bot 60 秒 20 条的冷却），飞书有官方插件。agentbox 不照搬任何一个，但两种拓扑分别对应它们的思路。

## 2. 两种拓扑

| | A. 一个实例，进程内 relay | B. 一 bot 一实例，飞书投递 |
|---|---|---|
| 对应参照 | Grok Bot：共享 VM + 内部消息 | OpenClaw：群即总线 |
| bot 间通道 | cc-connect `relay send --to <project>`，同步拿到回复 | 主 bot 在话题里 @ 专才，专才回话题并 @ 主 bot |
| 依赖的平台能力 | 无，飞书只负责显示 | 飞书 `include_bot` 权限（2026 年新开，见 §4） |
| 凭据隔离 | **没有**。四个 project 的 Claude Code 子进程都继承整个容器环境（源码判定：`agent/claudecode/session.go` 用 `os.Environ()` 再合并 project env），`HOME=/state` 也共用；隔离只剩约定与审计 | 有。一实例一份 `env`、一个 state 卷 |
| 爆炸半径 | 一个失控全灭 | 单个 |
| 延迟与形态 | 进程内，秒级，默认等 120 秒 | 飞书事件投递，秒级，等待无上限 |
| 需要的新东西 | 一份四 project 的 `config.toml` | 四个实例 + 四个飞书应用 + 权限申请 |
| 什么时候选 | 三家云归同一个团队管、同一密级，先把体验跑出来 | 云账号分属不同团队或密级，或 A 的单点不可接受 |

两者的协议规则（§6）、名册（§7）、每家云的接入件（§8）完全相同，从 A 迁到 B 只动部署形态，不动 bot 的提示词与技能。**建议从 A 起步**：它不需要申请任何新权限，一台构建机就能把整条链路跑通；等确认了「主 bot 会不会问对人、汇总质量够不够」这两个产品问题，再决定是否值得付 B 的隔离成本。

## 3. 拓扑 A：一个 cc-connect，四个 project

一个实例、一个容器、一个 cc-connect 进程，`config.toml` 里四个 `[[projects]]`，每个绑一个飞书应用。cc-connect 自带的 Multi-Bot Relay 就是为此设计的：把几个 bot 拉进同一个群，在群里 `/bind <project>` 逐个绑定，之后任一 bot 的 agent 会在系统提示里看到「可以用 `cc-connect relay send --to <project> "<message>"` 找其他 bot，`CC_PROJECT` 与 `CC_SESSION_KEY` 已设好」。

```toml
[relay]
timeout_secs = 600        # Cloud diagnostics run longer than the 120s default; 0 disables the wait limit
visibility = "summary"    # full | summary | none: how much of the relay round trip is echoed into the group

[[projects]]
name = "cloud-lead"
admin_from = "${ADMIN_FROM}"

[projects.agent]
type = "claudecode"

[projects.agent.options]
work_dir = "/workspace/lead"
mode = "acceptEdits"

[projects.agent.options.env]
ANTHROPIC_BASE_URL = "${ANTHROPIC_BASE_URL}"
ANTHROPIC_AUTH_TOKEN = "${ANTHROPIC_AUTH_TOKEN}"
# No cloud credentials here on purpose; see the isolation caveat below.

[[projects.platforms]]
type = "feishu"

[projects.platforms.options]
app_id = "${FEISHU_APP_ID_LEAD}"
app_secret = "${FEISHU_APP_SECRET_LEAD}"
allow_from = "${ALLOW_FROM_LEAD}"
thread_isolation = true   # one Feishu topic = one agent session, so concurrent questions do not share context

[[projects]]
name = "aws"
admin_from = "${ADMIN_FROM}"

[projects.agent]
type = "claudecode"

[projects.agent.options]
work_dir = "/workspace/aws"
mode = "acceptEdits"

[projects.agent.options.env]
ANTHROPIC_BASE_URL = "${ANTHROPIC_BASE_URL}"
ANTHROPIC_AUTH_TOKEN = "${ANTHROPIC_AUTH_TOKEN}"
AWS_ACCESS_KEY_ID = "${AWS_ACCESS_KEY_ID}"
AWS_SECRET_ACCESS_KEY = "${AWS_SECRET_ACCESS_KEY}"
AWS_DEFAULT_REGION = "${AWS_DEFAULT_REGION}"

[[projects.platforms]]
type = "feishu"

[projects.platforms.options]
app_id = "${FEISHU_APP_ID_AWS}"
app_secret = "${FEISHU_APP_SECRET_AWS}"
allow_from = "${ALLOW_FROM_AWS}"
thread_isolation = true

# aliyun and volcengine projects follow the same shape; see examples/aliyun/config.toml
# for the Alibaba Cloud variables and docs/CREDENTIALS.md for the rest.
```

表名不带 project 名（`[projects.agent]`，不是 `[projects.aws.agent]`），这个坑见 [INSTANCES §2](../INSTANCES.md)。

**relay 的语义（源码判定，`core/relay.go`、`core/engine.go`）：**

- 同步请求应答。主 bot 执行 `relay send` 后阻塞等专才回复，回复从 stdout 返回；等待上限 `timeout_secs`，超时只是不等了，专才的 agent 进程不会被杀。
- 目标必须是同一个 cc-connect 进程里的 project，且已在这个群 `/bind`。不满足分别报 `target engine not found` 与 `no binding for this chat`。所以 relay 不能跨容器，这也是拓扑 B 存在的原因。
- 专才为每个来源保留一个独立的 relay 会话（可 resume），所以主 bot 连续追问时专才记得上文。
- `visibility` 只控制群里额外回显多少（请求与回复各一条），不影响主 bot 拿到完整回复。

**隔离的真实边界。** 同容器意味着 `env_file` 里所有变量都在容器环境里，每个 project 的 Claude Code 子进程继承全部；`/state` 是同一个 HOME，`aws`、`aliyun` 写回家目录的 token 彼此可读。给每个 project 单独写 `[projects.agent.options.env]` 只是让「默认 CLI 行为」各用各的 AK，不是安全边界。接受这一点的前提与 [INSTANCES §6](../INSTANCES.md) 关于不设内存上限的前提相同：同一台机器上的实例都归可信的运维团队管。管不住就上拓扑 B。

## 4. 拓扑 B：一 bot 一实例，飞书群即总线

四个实例（`instances/cloud-lead`、`instances/aliyun`、`instances/aws`、`instances/volc`），照 `examples/aliyun/config.toml` 的模式各起一个，共用一张外部 `agentbox` 网络但**不靠网络通信**，通信走飞书。

**平台能力。** 飞书接收消息事件（`im.message.receive_v1`）的权限要求在 2026 年新增了两个带 `include_bot` 的范围：

| 权限 | 效果 |
|---|---|
| `im:message.group_at_msg.include_bot:readonly` | 收到「群聊中用户及群内机器人 @ 当前机器人」的消息 |
| `im:message.group_msg.include_bot:read` | 收到群里所有用户和其他机器人的消息，不含自己发的 |

只申请第一个：主 bot 与专才都只在被 @ 时动。事件里 `sender_type` 区分 `user`/`bot`，`mentions[].mentioned_type` 也有 `bot`。两个已知限制：Lark 国际版文档尚无这两个范围，租户是飞书还是 Lark 先在开发者后台确认；社区称仅企业自建应用可申请，未见官方原文。企微与钉钉都只在「用户 @ 机器人」时回调，没有 bot 对 bot 投递，这条拓扑只在飞书成立。

**cc-connect 侧要配的东西（源码判定，`platform/feishu/feishu.go`）：**

- 接收路径不按 `sender_type` 丢弃 bot 消息，只看「是否 @ 了本 bot」加 `allow_from`、`allow_chat`。所以专才的 `allow_from` 必须包含主 bot 的 open_id，主 bot 的 `allow_from` 必须包含三个专才的 open_id。open_id 按「应用 × 被看者」不同：主 bot 眼里的 AWS bot 与阿里云 bot 眼里的 AWS bot 不是同一个 id，取法是让人在群里 @ 一次目标 bot，从事件 `mentions[].id` 里读。
- `thread_isolation = true`：一个话题一个会话。主 bot 在话题里 @ 专才，专才的回复落在同一话题，主 bot 收到时进的是发起那个会话，「问了谁、谁回了」全在会话记忆里，不需要外部状态机。
- 出站 @ 用 `resolve_mentions = true` 加 `mention_map = { AWS = "ou_xxx", ALIYUN = "ou_xxx", VOLC = "ou_xxx" }`：agent 在回复里写 `@AWS`，cc-connect 换成飞书 `<at>` 标签触发对方事件。这个键的注释原文就是「Outbound bot-to-bot @name」，上游已预见此用法。
- `peer_bots = { "<app_id>" = "AWS" }` 让引用链里的对端 bot 显示成友好名。
- 超时：专才没回时主 bot 不会被唤醒。用 `cc-connect timer add --delay 10m --prompt "..."` 给自己留一条检查提醒，到点没收齐就先给人部分结论。

**退路。** 拿不到 `include_bot` 权限时按优先级：(1) 专才实例加第二个 service 开一扇 MCP 门（同信任域第二个 service 的写法见 [INSTANCES §1](../INSTANCES.md)），主 bot 用 Claude Code 原生 MCP 客户端直连，自己把要点贴回话题；(2) 主 bot 以用户身份发消息（`im:message.send_as_user`，需一个真实用户授权），专才按普通用户消息接收；(3) 轮询消息列表接口。A2A 协议留给要接阿里 Nacos、AWS AgentCore、火山 veADK 这类外部生态时，Claude Code 本身没有 A2A 客户端，先上它只会多一层桥。

## 5. 为什么不是一个 bot 带三个 subagent

Claude Code 的 subagent 可以限制工具与 MCP，但**继承父进程全部环境变量**，做不了凭据分隔；它也没有独立的飞书身份，人不能单独找 AWS 那个 subagent 说话；每次任务新起，没有自己的持久会话。

但在拓扑 A 里凭据本来就不隔离，所以「一个 bot 带四个 subagent」是它的**零成本起步形态**：一个飞书应用、没有 relay、记忆与上下文全在主 bot 自己的会话里。2026-09-13 的首个实例就是这么起的。什么时候把某家云拆成独立 bot：有人需要直接 @ 它对话，或者它需要自己的持久记忆。拆出去只是多一个 `[[projects]]` 和一个飞书应用，subagent 文件改成该 bot 的系统提示。

## 6. 协议规则

写进四个 bot 的系统提示（拓扑 A、B 相同）：

1. **只有主 bot 可以找其他 bot。** 专才收到来自 bot 的请求，只回给请求方，不找第三个 bot。跳数封死在 1。
2. **bot 发来的请求只做只读诊断。** 专才回复里给「建议动作」但不执行。要执行变更，必须由 `allow_from` 里的真人直接 @ 该专才确认；主 bot 不能转达审批。从专才的视角，主 bot 是不可信调用方，Trustwave 已演示过恶意 agent 用夸大的能力卡骗走全部任务。
3. **专才回复用固定结构**：结论、证据（跑过的命令与关键输出）、置信度、建议、未能确认的点。主 bot 靠这个结构汇总。
4. **主 bot 委托前先在话题里说一句正在问谁**，让人知道进度、能中途叫停。
5. **主 bot 汇总时逐条标注出处**（哪个专才、跑了什么），矛盾处指出来而不是抹平。

## 7. 主 bot 需要的名册与技能

主 bot 装一个 cloud-router 技能（挂 `/agent/skills-lock.json` 清单或放进主 bot 工作区，落法见 [SKILLS](../SKILLS.md)），内容三样：

| 组件 | 内容 |
|---|---|
| 名册 | 每个专才的名字、管哪家云哪些产品、能做什么（只读/可写）、怎么找它（拓扑 A 是 project 名，拓扑 B 是 `mention_map` 里的别名）。一份 YAML |
| 委托简报模板 | 目标、已知信息（账号、region、资源 id、时间窗）、期望回复格式、截止时间。Anthropic 的多 agent 研究系统里 lead 最常见的失误是简报太短 |
| 汇总模板 | §6 第 5 条的格式 |

路由判断写在系统提示里由模型做，不写关键词规则；判断不了就三家并行问，或反问人。

## 8. 每家云的接入件

| 云 | CLI（镜像） | 官方 Skills | 官方 MCP | 注意 |
|---|---|---|---|---|
| 阿里云 | `aliyun` 已在 `mise.toml` | `aliyun/alibabacloud-aiops-skills`（按产品分组，含 trouboper 等 playbook） | 托管 OpenAPI MCP，容器内用 `uvx alibabacloud.mcp-proxy` 走静态 AK | `aliyun utils mcp-proxy` 走 OAuth 交互登录，headless 容器用不了；`alibaba-cloud-ops-mcp-server` 自 2026-03 未更新 |
| AWS | `aws` 已在 `mise.toml` | `aws/agent-toolkit-for-aws/skills`（observability、billing、iam、security、operations） | `awslabs/mcp` 的 `aws-api-mcp-server`，加 cloudwatch、cloudtrail、billing | `READ_OPERATIONS_ONLY` 起步，写操作再开 `REQUIRE_MUTATION_CONSENT` |
| 腾讯云 | `tccli` 已在 `mise.toml`（`pipx:`，纯 Python 包，无二进制发行） | 未调研 | `tccli` 无原生 MCP | 认 `TENCENTCLOUD_SECRET_ID`、`TENCENTCLOUD_SECRET_KEY`、`TENCENTCLOUD_REGION`；profile 选择时环境变量优先级最低，命令必带 `--profile` |
| 火山引擎 | `ve` 已在 `mise.toml`（`github:volcengine/volcengine-cli`）。不要用 npm 包装：它的 postinstall 会往 `~/.claude/skills` 自动写火山 skills，绕开 [SKILLS](../SKILLS.md) 的清单机制 | `volcengine/volcengine-skills` | `ve mcp` 原生，CLI 自身就是 MCP server；`volcengine/mcp-server` 按产品拆了 85 个 | `ve mcp` 没有 API 白名单，边界全靠 IAM；认 `VOLCENGINE_ACCESS_KEY`、`VOLCENGINE_SECRET_KEY`、`VOLCENGINE_REGION` |

凭据规则三家一致，都落在 [CREDENTIALS](../CREDENTIALS.md) 现有的两条通道里：每个专才一个独立 RAM/IAM 身份、只读起步、STS 短期凭据优先、写操作过人工审批、审计靠 CloudTrail/ActionTrail。一家云有多个账号时（阿里云两个、AWS 三个这种），账号不再拆 bot，而是做成带别名的 profile，别名名册、AssumeRole 角色与防误动账号的强制层见 [CLOUD_ACCOUNTS](CLOUD_ACCOUNTS.md)。主 bot 的托管层 `managed-settings.json` 拒绝一切云 CLI，它本来没有凭据，这是双保险。

## 9. 从哪一步开始

1. **拓扑 A 在构建机上跑通**：四个测试飞书应用、一份四 project 配置、一个群 `/bind` 四次，问主 bot 一个跨两家云的问题，看它会不会 relay、汇总长什么样。这一步不需要任何新权限。
2. 同时在开发者后台确认能否申请 `im:message.group_at_msg.include_bot:readonly`。能，则拓扑 B 有路；不能，B 的退路是 §4 末尾那三条。
3. 产品体验确认后再决定是否迁到 B。迁移只改部署形态。
