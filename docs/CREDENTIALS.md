# 凭据：密级、通道、映射

> 契约。变量名、文件位置、密级、提供通道。**任何文档、对话、报告、分享链接里都不允许出现明文值。**

## 1. 密级

| 密级 | 定义 | 处理 |
|---|---|---|
| **S0 极密** | 泄露即可无限制使用上游资源或接管系统 | `0600`、单一属主、备好轮换预案 |
| **S1 机密** | 泄露可越权访问特定系统或消耗特定预算 | `0600`、按实例最小授权 |
| **S2 内部** | 非凭据，但暴露拓扑 | 不外发，可进内部文档 |

| 项 | 密级 |
|---|---|
| 平台应用密钥（如 `FEISHU_APP_SECRET`） | S0 |
| 模型网关 token（`ANTHROPIC_AUTH_TOKEN`） | master key 是 S0，专属虚拟 key 是 S1 |
| 其他 CLI 凭据、git 机器人私钥、kubeconfig | S1（集群 admin 的 kubeconfig 是 S0） |
| 应用 ID、网关地址、放行名单 open_id、主机地址 | S2 |

网关 token 必须用有预算与限流的专属虚拟 key，不用 master key。

## 2. 三条通道

凭据按形态走三条通道，每条只有一处真相：

| 形态 | 部署仓库里 | 到容器 | 规则 |
|---|---|---|---|
| **环境变量型** | `instances/<name>/env`，0600 | rsync → compose `env_file` → `config.toml` 的 `[projects.agent.options.env]` 写 `${占位符}` → 桥接器注入 agent 子进程 | 变量名用工具自己认的名字，不起别名 |
| **文件型**（工具按家目录默认路径读） | `instances/<name>/home/`，照 `~` 的结构摆 | rsync 0600 → `:ro` 挂 `/agent/home` → entrypoint 每次启动复制进 `/state`（即 `~`） | 声明的文件赢；没声明的（`known_hosts`、会话、缓存）不动；进容器一律文件 `0600`、目录 `0700`。compose 永远只有 `./home:/agent/home:ro` 一行，不需要 `KUBECONFIG`、`GIT_SSH_COMMAND` 这类指路变量 |
| **agent 要改写的文件**（如仓库 gitignored 的 `secrets/`） | `instances/<name>/workspace-init/` | rsync `--ignore-existing` 直接进服务器工作区 | 不进服务器的 `instances/` 镜像，服务器上只有工作区一份；仓库那份是备份不是同步源 |

优先环境变量型。文件型只用于工具不认环境变量的场景：kubeconfig、SSH 私钥与 `.ssh/config`、路径不可改的云 CLI 配置目录。`~` 下哪个是文件哪个是目录由工具决定，`home/` 只是照抄：`.ssh/` 是目录，里面 `config` 加 N 把私钥；`.kube/config` 是一个文件。文件型凭据不再以 `/agent/<文件>:ro` 单挂，`/agent/` 下只有 `config.toml`、`skills-lock.json`、`home`。agent 只读不改、由运维维护的非凭据声明文件（如云账号名册 `accounts.yaml`）也放 `home/`，落到 `~/accounts.yaml`：同一条复制链路，改了重启即生效，不用再加挂载。

为什么是复制而不是直接挂宿主目录：只读挂则工具写不了 `known_hosts` 和回写的令牌，可写挂则配置没有真相。`home/` 是声明层，`/state` 是运行层。工具自己回写到同名文件的改动（`aws configure`、`gh auth`）重启即被覆盖。

`config.toml` 只写 `${占位符}`，进 git；entrypoint 启动前校验每个占位符可解析，缺则 `exit 2` 并列全。不能用 shell rc 文件：agent 是非交互子进程，读不到 `~/.bashrc`、`/etc/profile.d`。本地开发用 `examples/<name>/env`，不在部署链路上。部署仓库布局见 `.claude/skills/deploy/references/deploy-repo.md`。

## 3. 映射表

`HOME=/state`，所有"家目录配置"落在 state 卷；缓存已由镜像 ENV 全部指向 `/cache`。

| 工具 | 容器内默认位置 | 认的环境变量 | 推荐通道 | 密级 |
|---|---|---|---|---|
| Claude Code | 可变状态 `/state/.claude/`、`/state/.claude.json`；只读托管层 `/etc/claude-code/` | `ANTHROPIC_BASE_URL`、`ANTHROPIC_AUTH_TOKEN`、`ANTHROPIC_MODEL` 与 `ANTHROPIC_DEFAULT_*_MODEL`、`CLAUDE_CODE_SUBAGENT_MODEL`、`CLAUDE_CODE_AUTO_COMPACT_WINDOW` | 环境变量；技能与策略挂 `/etc/claude-code:ro`（[SKILLS](SKILLS.md)） | S0/S1 |
| cc-connect | `/state/.cc-connect/`（data-dir、`run/api.sock`）、锁文件 `/agent/.config.toml.lock` | 由 `config.toml` 驱动 | `config.toml` 占位符 | S0 |
| git | `/state/.gitconfig`、`/state/.ssh/{config,known_hosts,<key>}` | `GIT_AUTHOR_NAME` 等 | `home/.ssh/<key>` 加 `home/.ssh/config`（`Host` 段写 `IdentityFile ~/.ssh/<key>`、`IdentitiesOnly yes`）；`known_hosts` 只落 state | S1 |
| gh | `/state/.config/gh/hosts.yml` | `GH_TOKEN`、`GH_HOST` | 环境变量 | S1 |
| glab | `/state/.config/glab-cli/config.yml` | `GITLAB_TOKEN`、`GITLAB_HOST` | 环境变量 | S1 |
| kubectl / helmfile | `/state/.kube/config` | `KUBECONFIG` | `home/.kube/config`；多集群多份文件时用 `KUBECONFIG` 列 `~/.kube/` 下的路径 | S0/S1 |
| helm | 仓库列表 `/state/.config/helm/repositories.yaml`；registry 登录 `/state/.config/helm/registry/config.json`；插件 `/opt/helm/plugins`（镜像内） | `HELM_CONFIG_HOME`（已设） | 私有 chart 仓库凭据放 `home/.config/helm/registry/config.json` | S1 |
| aws | `/state/.aws/{config,credentials}` | `AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY`、`AWS_DEFAULT_REGION`、`AWS_PROFILE` | 环境变量；多账号时 `home/.aws/config` | S0/S1 |
| aliyun | `/state/.aliyun/config.json` | `ALIBABA_CLOUD_ACCESS_KEY_ID`、`ALIBABA_CLOUD_ACCESS_KEY_SECRET`、`ALIBABA_CLOUD_REGION_ID` | 环境变量；多账号时 `home/.aliyun/config.json`（CLI 会写回，不能 `:ro` 直挂） | S0/S1 |
| ve（火山引擎） | `/state/.volcengine/config.json`（路径不可改） | `VOLCENGINE_ACCESS_KEY`、`VOLCENGINE_SECRET_KEY`、`VOLCENGINE_REGION`、`VOLCENGINE_PROFILE`、`VOLCENGINE_DISABLE_DEFAULT_CREDENTIALS` | 环境变量；多账号时 `home/.volcengine/config.json` | S0/S1 |
| tccli（腾讯云） | `/state/.tccli/<profile>.configure`、`<profile>.credential` | `TENCENTCLOUD_SECRET_ID`、`TENCENTCLOUD_SECRET_KEY`、`TENCENTCLOUD_REGION`、`TENCENTCLOUD_TOKEN`、`TCCLI_PROFILE`（优先级：命令行 > 文件 > 环境变量） | 环境变量；多账号时 `home/.tccli/` | S0/S1 |
| cloudflared | `/state/.cloudflared/` | `TUNNEL_TOKEN` | 环境变量 | S1 |
| npm | `/state/.npmrc` | `npm_config_registry`、`npm_config_disturl`（cn profile 已设） | 私有源 token 放 `home/.npmrc` | S1 |
| go | 无家目录配置 | `GOPROXY`、`GOSUMDB`（profile 已设）、`GOPRIVATE`、`GONOSUMDB` | 私有模块走 `GOPRIVATE`，认证靠 git 的 SSH 身份 | S2 |
| pip / uv | `/state/.config/pip/pip.conf`、`/state/.config/uv/uv.toml` | `PIP_INDEX_URL`、`UV_DEFAULT_INDEX`、`HF_ENDPOINT`（cn profile 已设） | 环境变量 | S1 |
| mise | `/etc/mise/`（镜像内只读）、`/state/.local/state/mise/` | 运行期已锁死离线 | 无需配置 | 无 |

凡是工具自己会把 token 写回家目录的（gh、glab、aws、aliyun、helm registry），state 卷就是密钥载体，备份与销毁按 S1 处理。进镜像的工具在 `mise.toml` 加声明后必须在本表加一行，否则部署者得自己去查。

## 4. 谁能读到这些

```toml
mode = "bypassPermissions"    # agent 执行任何命令不再询问
allow_from = "*"              # 任何平台用户都能驱动
```

两者叠加：**任何能在聊天平台找到这个机器人的人，都能让 agent `cat` 出容器内全部密钥。** `allow_from = "*"` 只适合本地测试。

| 防线 | 作用 |
|---|---|
| `allow_from` / `admin_from` 写明确的 open_id 列表 | 唯一真正挡住"谁能驱动 agent"的机制 |
| 一信任域一容器、每实例独立 `env_file`、逐项注入 | 每个 agent 只读它需要的密钥 |
| 虚拟 key 而非 master key | S0 降成 S1 |

两个已知未封的口子。**容器之间不隔离**：所有 agentbox 容器共用一张 `agentbox` 网络（[INSTANCES](INSTANCES.md) §6），信任域的边界是 `env_file` 与卷，不是网段。**出站不受限**：容器必须能出站连平台与模型网关，compose 没有 egress 白名单；agent 被提示注入后可以把密钥发到任何外网地址，上面三道防线都不能阻止外传本身。生产环境要么接受，要么在容器外用网络策略或代理只放行必要目标。

## 5. 红线

1. 明文密钥不进 git、文档、聊天、报告、分享链接。
2. 密钥文件 `0600`，发现 `644` 立即收紧。
3. 仓库里 env 模板以 `.example` 结尾，只放 `xxxx` 形态占位值；不允许出现未加 `.example` 的 env 文件（`scripts/test.sh` 断言）。
4. 改完密钥文件删掉 `cp -a` 留下的 `.bak`。
5. 生产写操作必须人工明确授权。

部署仓库把 `env` 明文提交进 git 是有意的取舍（[DECISIONS](DECISIONS.md)）：仓库权限是唯一防线，一旦泄露 `git rm` 清不掉历史，只能全量轮换。

## 6. 泄露应急

| 泄露项 | 立即动作 |
|---|---|
| 平台应用密钥 | 平台后台重置 → 更新 `env` → 重建容器 → 查应用调用日志 |
| 网关虚拟 key | 重签 → 换 `env` → 查该 key 花费明细 |
| 上游 master key | 改密钥源 → 滚动重启网关 → 通知依赖方 |
| git 机器人私钥 | 远端删公钥 → 生成新密钥 → 挂新公钥 → 查账号事件（[GIT_IDENTITY](GIT_IDENTITY.md) §8） |
| 部署仓库泄露 | 轮换该仓库覆盖的全部平台密钥与网关 token；收紧或吊销仓库访问权限 |

"改了声明式配置"不等于"吊销了远端凭据"，应急时直接调 API 或到控制台操作。

## 7. 先验证网关再起实例

网关地址或 key 不对时 Claude Code 不报错，而是无输出挂住，表现为机器人收到消息后没有任何回复。起实例前在容器里用 curl 直接打一次（`ANTHROPIC_MODEL` 需已在 env 里设置）：

```bash
docker compose exec -T demo sh -c 'curl -sS -m 20 "$ANTHROPIC_BASE_URL/v1/messages" \
  -H "x-api-key: $ANTHROPIC_AUTH_TOKEN" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
  -d "{\"model\":\"${ANTHROPIC_MODEL}\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}"'
```

返回 `content` 才算通；`401`/`403` 是 key 与该主机不匹配（阿里云百炼的 key 按区域和产品线分主机）。手工测 `claude -p` 时要加 `</dev/null`，否则它一直等 stdin 的 EOF。
