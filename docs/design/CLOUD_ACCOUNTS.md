# 多账号：一家云多个账号时 bot、别名与凭据怎么组织

> 状态：设计稿，未实现。本文描述的拓扑没有在真实环境跑过，标「源码判定」的结论只来自读源码。不要把这里的内容当作现状引用；实现一段就把契约部分挪进正文文档。

[MULTI_CLOUD](MULTI_CLOUD.md) 解决的是「几家云、几个 bot、怎么协作」。这份文档解决下一层：阿里云有 2 个账号、AWS 有 3 个账号，都要纳管，每个账号一个别名，架构上怎么摆才最优。结论先行：**bot 是对话与身份单位，账号是凭据与授权单位，两根轴不绑死。一家云一个专才 bot，账号做成带别名的 profile，用名册、无默认 profile、托管钩子、身份回显、AssumeRole 五件事保证「问哪个账号就动哪个账号」。** 新增一个账号不新增任何 bot。

与 [MULTI_CLOUD](MULTI_CLOUD.md) 相同的约定：标「源码判定」的来自读 cc-connect `main`（commit 757b4df）与各 CLI 仓库源码，标「文档」的来自官方文档，都不等于真机跑通；未跑通的项目在 [ROADMAP](../ROADMAP.md)。

## 1. 三种摆法

| | 1. 账号即 bot | 2. 云即 bot，账号即 profile（推荐） | 3. 一个 bot 管全部 |
|---|---|---|---|
| 形态 | `aliyun-a`、`aliyun-b`、`aws-x`、`aws-y`、`aws-z` 五个 project | `aliyun`、`aws`、`volc` 三个 project，账号是各自 profile 文件里的条目 | 一个 project，所有云所有账号 |
| 飞书应用数 | 每账号一个。cc-connect 守护进程严格校验，每个 project 至少要一个 `[[projects.platforms]]`（源码判定，`config/config.go`），relay 不能绕过这一点 | 每云一个 | 一个 |
| 新增一个账号 | 新飞书应用 + 新 project + 群里重新 `/bind` | 名册加一行，重新渲染 profile 文件，重启该专才 | 同左 |
| 误动账号的风险 | 最低，一个 bot 只有一套凭据 | 靠 §4 的强制层控制 | 同左，且工具面最大 |
| 跨账号任务（对比、巡检） | 主 bot 扇出到多个 bot 再汇总 | 专才内部按 profile 循环或并行 | 同左 |
| 云厂商专业性 | 一个 bot 一家云 | 一个 bot 一家云 | 一个 bot 三家云的 skills 与 MCP 全装，超过 Anthropic 建议的单 agent 工具面（15 到 20 个工具就该拆） |
| 凭据隔离 | 在单实例方案下**三种都没有**：同容器所有 project 的子进程继承整个容器环境（[MULTI_CLOUD §3](MULTI_CLOUD.md)） | 同左 | 同左 |
| 常驻进程 | 五个 Claude Code | 三个 | 一个 |

方案 1 唯一的技术收益「一 bot 一套凭据」在单实例下不成立，剩下的只有组织收益：某个账号归另一个团队、他们想要一个只属于自己的机器人来对话。有这种需求就把那个账号单拆成 bot，其余仍走方案 2。方案 3 是方案 2 的退化形态，账号少、人少时可以先这么起，账号一多就按云拆开，拆开只是把 profile 文件按云分文件。

## 2. 别名与名册

别名是人、主 bot、专才、profile 文件、审计日志五方共用的同一个词，所以要满足：全局唯一（跨云不重名）、看得出云与环境、不含账号 ID 这类会变的东西。约定 `<cloud>-<biz>-<env>`：

```
aliyun-uufly-prod    aliyun-uufly-staging
aws-uufly-prod       aws-uufly-dev        aws-data-prod
volc-media-prod
```

名册是唯一真相，一份 YAML，进部署仓库，放在每个专才与主 bot 实例目录的 `home/accounts.yaml`，随 home 层复制到容器内 `~/accounts.yaml`（[CREDENTIALS](../CREDENTIALS.md) §2）：

```yaml
# accounts.yaml: the single source for aliases. Everything else (profile files,
# the lead's roster, the hook allowlist) is rendered from this file.
- alias: aws-uufly-prod
  cloud: aws
  account_id: "123456789012"
  display: uufly 生产
  env: prod
  owner: ops
  default_region: ap-southeast-1
  tiers:
    read:  { role_arn: "arn:aws:iam::123456789012:role/AgentReadOnly" }
    admin: { role_arn: "arn:aws:iam::123456789012:role/AgentAdmin" }
- alias: aliyun-uufly-prod
  cloud: aliyun
  account_id: "1234567890123456"
  display: uufly 生产
  env: prod
  owner: ops
  default_region: cn-hangzhou
  tiers:
    read:  { role_arn: "acs:ram::1234567890123456:role/AgentReadOnly" }
```

同一份文件渲染出四样东西，渲染脚本待做（见 ROADMAP）：

| 产物 | 给谁 | 内容 |
|---|---|---|
| `home/.aws/config` | AWS 专才 | 每个别名一个 `[profile <alias>]`，只有 `role_arn`、`source_profile`、`role_session_name`、`region`，没有 `[default]` |
| `home/.aliyun/config.json`、`home/.volcengine/config.json` | 阿里云、火山专才 | 每个别名一个 profile，模式为角色扮演。都是实例目录 `home/` 里的文件，entrypoint 启动时复制进 `/state`（[CREDENTIALS](../CREDENTIALS.md) §2），不再 `:ro` 直挂 `/state/.aliyun` 这类路径 |
| 名册摘要 | 主 bot | 别名、显示名、环境、owner，不含任何 ARN |
| 钩子白名单 | 托管层 | 每个专才允许出现的别名列表 |

写操作用独立别名 `<alias>-admin`，对应 `tiers.admin` 的角色。这样「只读还是可写」在别名上就可见，钩子与审计都能按字面判断。

## 3. 凭据：一家云一个长期身份，每个账号一个角色

每家云只保留一个长期凭据（运维账号下的 RAM/IAM 用户），它唯一的权限是 AssumeRole；每个纳管账号里建 `AgentReadOnly`（挂平台只读策略）与按需的 `AgentAdmin`，信任运维账号。别名 → 角色的映射就是 profile 文件。收益：长期密钥只有三个而不是五个以上；每次调用拿到的是 15 分钟到 1 小时的短期凭据；审计日志里带 `role_session_name`，能看出是哪个 bot 在哪个别名下做的。

三家 CLI 的机制（文档）：

| | AWS CLI v2 | 阿里云 CLI | 火山引擎 CLI（`ve`） |
|---|---|---|---|
| 配置文件能否改位置 | 能，`AWS_CONFIG_FILE`、`AWS_SHARED_CREDENTIALS_FILE` | 能，但只有命令行 `--config-path`，**没有环境变量** | **不能**，固定 `~/.volcengine/config.json` |
| 选 profile | `--profile` > `AWS_PROFILE` > `[default]` | `--profile` > `ALIBABA_CLOUD_PROFILE` > 文件里的 `current` | `--profile` > 文件里的 `current` > `VOLCENGINE_PROFILE`（环境变量排在 `current` 之后） |
| 做到「不带别名就失败」 | 不写 `[default]`，并设 `AWS_EC2_METADATA_DISABLED=true` 防止链条落到 IMDS；报 `Unable to locate credentials`，退出码 253 | `current` 是指针，删掉活动 profile 会自动指向列表第一个；只能让 `current` 指向一个故意无效的 profile（未实测） | `VOLCENGINE_DISABLE_DEFAULT_CREDENTIALS=true`，无活动 profile 直接报错 |
| 角色扮演模式 | `[profile x]` 写 `role_arn` + `source_profile`，`role_session_name` 固定为 bot 名，`duration_seconds` 900 起 | `--mode ChainableRamRoleArn --source-profile <ak-profile> --ram-role-arn ... --role-session-name ... --expired-seconds 900`，到期自动续 | `ve configure set --mode ramrolearn --role-name ... --account-id ...`，未见会话名与时长参数 |
| 身份回显 | `aws sts get-caller-identity`，不需要任何权限 | `aliyun sts GetCallerIdentity`，`IdentityType` 会显示 `AssumedRoleUser` | `ve sts GetCallerIdentity`，输出 `AccountId`、`Trn` |
| 审计里怎么看 | CloudTrail `userIdentity.type=AssumedRole`，ARN 末段是 session name | ActionTrail `userName={roleName}:{sessionName}`，`stsTokenPlayerUid` 是扮演方账号 | 云审计 `UserName=${RoleName}/${RoleSessionName}` |
| 组织级自动角色 | Organizations 建的账号自带 `OrganizationAccountAccessRole`（管理员权限，别直接给 bot 用） | 资源目录给每个成员建 `ResourceDirectoryAccountAccessRole`（同上） | 企业组织**不自动建角色**，逐个成员手建 |
| 只读托管策略 | `ReadOnlyAccess` | `AliyunReadOnlyAccess`（名称未复核） | `ReadOnlyAccess` |

三个落地细节：

- **阿里云 3.5.0 起 `current` 必须指向文件里存在的 profile**，否则连 `aliyun version` 都拒绝（devops-agent 实测，3.4.10 不检查）。「无默认账号」写成 `current` 指向一个空 AK 的哨兵 profile `none`：不带 `--profile` 报凭据未配置，带则正常。`verify-profiles.sh` 在部署前检查这一点。
- **阿里云没有配置路径的环境变量**：渲染产物放 `home/.aliyun/config.json`，entrypoint 启动时复制进 `/state/.aliyun/`（[CREDENTIALS](../CREDENTIALS.md) §2 的家目录声明层）。阿里云 CLI 会把续期后的 STS 令牌写回 `config.json`（源码判定，`config/profile.go`），复制件可写所以续期不受影响，下次启动又回到声明值；未实测。
- **火山不能改路径**，同样放 `home/.volcengine/config.json`；`ve configure set` 会把 `current` 切到刚配的 profile，渲染时最后一步要把 `current` 置回无效值。
- **AWS 的 STS 缓存**在 `~/.aws/cli/cache`，落在 `/state`，可写，无事。
- 做不到跨账号角色（比如账号不在同一组织且对方不肯建角色）时退化为每个别名一份静态 AK，仍然写进同一份 profile 文件、仍然按别名调用，只是长期密钥变多、审计里看不到 session name。IAM Identity Center / SSO 登录需要人在浏览器操作，不适合无人值守容器（文档）。

## 4. 强制层：三道，缺一不可

只靠提示词让 agent「记得带 `--profile`」不够。三道从软到硬：

**部署期校验（先于一切）。** `.claude/skills/deploy/scripts/verify-profiles.sh <host> <instance>` 在操作者本机对实例的每个 profile 跑一次 `GetCallerIdentity`，用的是实例自己的 profile 文件而不是操作者的 `~/.aws`，账号 ID 必须等于名册里写的，否则 FAIL、退出 1；本机没装的 CLI 给 SKIP 而不是 PASS。名册与密钥的漂移在这里被拦住，运行期就不必再让 agent 每个任务先自证账号，只需保留「不确定人指的是哪个账号就反问」。2026-09-13 对首个实例的六个 profile 跑通。

**提示层（名册 + 规则）。** 专才系统提示：每条云命令必须带 `--profile <alias>`；每个任务开始时回显一次 `GetCallerIdentity` 的账号 ID（部署期校验上线后可去掉）；请求里没有别名或别名与账号 ID 对不上就停下来问，不猜；`-admin` 别名只在真人明确指名时使用。

**钩子层（托管 `managed-settings.json` 里的 PreToolUse）。** Claude Code 的 PreToolUse 钩子拿到 Bash 的完整命令文本，返回 `permissionDecision = deny` 加原因就能拦下，放在 `/etc/claude-code/managed-settings.json` 里 agent 与项目配置都改不掉（文档）。规则三条：命令文本里出现 `aws`、`aliyun`、`ve` 之一，却没有 `--profile <白名单内别名>`，拒绝；出现 `-admin` 别名而当前会话没有拿到人工确认，拒绝；命令含 `configure`、`AWS_PROFILE=`、`ALIBABA_CLOUD_PROFILE=`、`VOLCENGINE_PROFILE=`、`--config-path` 这类改选路的写法，拒绝。钩子看整条命令字符串，所以 `sh -c`、管道、`$()` 里的写法一样被拦，代价是偶尔误伤（比如 `grep aws` 这种），误伤只会让 agent 换个写法。两个已知限制：headless 下 `permissionDecision = ask` 无处弹窗，只能 allow/deny（文档）；纯 `permissions.deny` 的 `Bash(aws *)` 模式只做前缀匹配，挡不住组合命令，所以用钩子而不是模式。

**环境与沙箱层。** `sandbox.credentials.envVars` 把 `AWS_PROFILE`、`ALIBABA_CLOUD_PROFILE`、`VOLCENGINE_PROFILE` 以及三家的 AK 变量设为 `deny`，沙箱内命令看不到它们（文档），于是选账号只剩 profile 文件这一条路；长期 AK 只出现在 profile 文件的 `source_profile` 条目里，不再进 `[projects.agent.options.env]`。

**人工确认落在哪。** 写操作有两层：云侧，`-admin` 别名对应的角色才有写权限，只读别名怎么写都写不了；流程侧，`-admin` 别名的命令不进 cc-connect 的免确认列表，走它的权限确认（`mode = "acceptEdits"` 下命令本就需要确认），由 `admin_from` 的人在飞书里放行。来自主 bot 的 relay 请求按 [MULTI_CLOUD §6](MULTI_CLOUD.md) 只做只读，不会触碰 `-admin` 别名。cc-connect 把权限确认送到聊天里这一段本仓库已在依赖但未在多账号场景实测。

## 5. 主 bot 与专才的分工

- 主 bot 的名册摘要只有别名、显示名、环境、owner。人说「看一下 uufly 生产的 ECS」，主 bot 解析成 `aliyun-uufly-prod`，简报里写别名而不是显示名；解析不了就问人；人没说环境时默认非生产并在回复里说明。
- 「全部账号」类请求（巡检、成本对比）由专才内部处理：按名册里自己这家云的别名循环，或者用 subagent 并行，每个 subagent 一个别名。subagent 继承环境变量在这里不是问题，因为凭据不在环境变量里而在 profile 文件里，subagent 同样受托管钩子约束。
- 专才每条回复都带账号回显。主 bot 汇总时保留回显，人一眼看到每条结论出自哪个账号。

## 6. 新增一个账号

1. 在目标账号里建 `AgentReadOnly`（按需 `AgentAdmin`），信任运维账号，挂只读策略。
2. `accounts.yaml` 加一条。
3. 重新渲染四样产物，提交部署仓库，`deploy` 那个专才。
4. 在飞书里让专才对新别名跑一次身份回显，账号 ID 对上即完成。

没有新飞书应用、没有新 bot、没有新 project、主 bot 不用改。

## 7. 未验证与待做

| 事项 | 状态 |
|---|---|
| 名册渲染脚本（YAML → 三份 profile 文件 + 主 bot 摘要 + 钩子白名单） | 待做 |
| 阿里云 CLI 只读 `config.json` 下 STS 续期是否失败；entrypoint 复制方案 | 未实测 |
| 多个话题会话同时用同一家云的不同 profile 时，阿里云 CLI 并发写回 `config.json` 是否互相覆盖（AWS 缓存按 profile 分文件，无此问题） | 未实测 |
| 火山 `ramrolearn` 模式的会话名与时长 | 文档未见，需实测 |
| 托管 PreToolUse 钩子在 cc-connect 拉起的 headless 会话里是否生效、`sandbox.credentials.envVars` 在 Linux 容器里是否生效 | 未实测 |
| cc-connect 对 `-admin` 别名命令的权限确认是否送到飞书 | 本仓库已依赖，多账号场景未实测 |

这些都登记在 [ROADMAP](../ROADMAP.md)。
