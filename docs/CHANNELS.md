# 聊天平台：应用侧要开什么

> 契约。每个聊天平台的机器人在平台后台必须具备的权限、事件、回调，以及凭据落到哪个变量。cc-connect 自身的选项以[上游文档](https://github.com/chenhg5/cc-connect/tree/main/docs)为准，这里只写 agentbox 实例依赖的部分。

## 1. 所有平台共用的规则

- **必须用长连接。** 容器不开入站端口，没有公网 URL，任何依赖 webhook 回调的接入方式都不得使用。
- **一个平台应用只能有一个 cc-connect 消费者。** 长连接独占，第二个实例接同一应用会互相抢消息。换实例接管必须换应用，或先停旧实例。
- **应用密钥是 S0，只走环境变量通道。** 变量名、密级、部署仓库位置见 [CREDENTIALS](CREDENTIALS.md) §1–§2。应用 ID 与放行名单 open_id 是 S2。
- **放行名单 open_id 是「用户 × 应用」的组合。** 换应用后必须重新取值，取法是让人在聊天里对机器人发 `/whoami`，把回显的 ID 填进 `allow_from` / `admin_from`。填错是 fail closed。
- lark-cli 只能消费事件，不能给应用加权限、事件或回调；缺 scope 时它输出 `console_url` 让人去后台点。后台配置必须由人（或 §2.1 的扫码模板）完成。

## 2. 飞书

### 2.1 建应用的两条路

**扫码模板（上游命令）。** cc-connect 内置 `feishu new`：向飞书注册接口申请 `PersonalAgent` 模板应用，终端出二维码，用飞书手机 App 扫码建应用并回填凭据；飞书按模板预配权限与事件订阅。任意装有 cc-connect 的机器都能跑：

```bash
cc-connect feishu new --config /tmp/onboard.toml --project demo --qr-image /tmp/qr.png
# Lark international tenant: add --platform-type lark
```

`--config` 指向一个临时文件，只用来接收 `app_id` / `app_secret`；抄进部署仓库 `env` 后必须删掉临时文件。镜像内跑通这条路是 [ROADMAP](ROADMAP.md) 事项，跑通前以后台核验为准。

**后台手建。** [开放平台](https://open.feishu.cn/) 控制台 → 创建企业自建应用 → 「应用能力」启用机器人 → 「凭据与基础信息」取 App ID / App Secret → 按 §2.2 配权限、事件、回调 → 「版本管理与发布」创建版本并发布。

### 2.2 应用必须具备的配置

两条路的终态相同，以后台实际状态为准。「权限管理 → 批量导入」接受下面的 JSON，可整段粘贴：

```json
{
  "scopes": {
    "tenant": [
      "im:message",
      "im:message.group_at_msg:readonly",
      "im:message.p2p_msg:readonly",
      "im:message:readonly",
      "im:message:send_as_bot"
    ],
    "user": []
  }
}
```

| 项 | 位置 | 值 |
|---|---|---|
| 事件 | 事件与回调 → 事件配置 | 订阅方式「使用长连接接收事件」；添加 `im.message.receive_v1` |
| 回调 | 事件与回调 → 回调配置 | 订阅方式「使用长连接接收事件」；添加 `card.action.trigger` |
| 生效 | 版本管理与发布 | 改权限、事件、回调后都要创建新版本并发布，企业租户还需管理员审批 |

不订阅 `card.action.trigger` 时，权限确认、provider 切换等卡片按钮点了没反应，只能在 `config.toml` 里设 `enable_feishu_card = false` 退回纯文本。

按功能追加的权限：

| 开启的选项 | 额外需要 |
|---|---|
| `resolve_mentions = true`（出站 `@显示名` 换成原生 at） | `im:chat:readonly`、`im:chat.members:read`、`im:chat` 三者之一 |
| `group_chat_history_share = true`（未 @ 的群消息进上下文） | `im:message.group_msg`（敏感权限） |

### 2.3 凭据与变量

| 变量 | 内容 | 密级 |
|---|---|---|
| `FEISHU_APP_ID` | App ID，`cli_` 开头 | S2 |
| `FEISHU_APP_SECRET` | App Secret，后台只显示一次，忘了只能重置 | S0 |
| `ALLOW_FROM` / `ADMIN_FROM` | 该应用下的用户 open_id，`ou_` 开头 | S2 |

同实例第二个 project 的变量带后缀（`FEISHU_APP_ID_<NAME>`），见 [INSTANCES](INSTANCES.md) §2。机器人自己的 open_id 与 App ID 不是一回事，cc-connect 启动日志 `feishu: bot identified open_id=` 一行有它。

## 3. 企业微信

本仓库尚无企微实例；本节只写平台侧事实，首个实例上线后补变量名与实测。

cc-connect 支持两种模式，agentbox 只允许「智能机器人 + WebSocket 长连接」：管理后台「应用管理 → 智能机器人 → 创建智能机器人」，建完得到 BotID 与 Secret（Secret 只显示一次）。没有权限、事件、回调要配。`config.toml` 里 `type = "wecom"`，`mode = "websocket"`，`bot_id` / `bot_secret` 写占位符。限制：同一机器人只允许一条长连接，30 条/分钟、1000 条/小时。自建应用的 webhook 回调模式需要公网 URL 与 IP 白名单，按 §1 不得使用。
