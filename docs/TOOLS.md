# 工具凭据与配置映射

镜像里每个工具把配置和凭据放在哪、认哪些环境变量、部署时该怎么给。`HOME=/state`，所以所有"家目录配置"都落在 state 卷里；缓存已由镜像 ENV 全部指向 `/cache`，本文不重复。

## 1. 两条提供通道

| 凭据形态 | 通道 | 做法 |
|---|---|---|
| 环境变量型 | `env_file` → `config.toml` 的 `[projects.agent.options.env]` 写 `${占位符}` → 桥接器注入 agent 子进程 | 变量名用工具自己认的名字，不要再起别名 |
| 文件型 | 实例目录的 `home/` 照家目录结构摆（`home/.ssh/config`、`home/.kube/config`……），整目录 `:ro` 挂到 `/agent/home`，entrypoint 每次启动复制进 `/state`（即 `~`） | 工具按默认路径找到文件，不需要 `KUBECONFIG`、`GIT_SSH_COMMAND` 这类指路变量，compose 永远只有 `./home:/agent/home:ro` 一行 |

优先用环境变量型。文件型只用于工具不支持环境变量的场景（kubeconfig、SSH 私钥与 `.ssh/config`、路径不可改的云 CLI 配置目录）。两种都不写进 `config.toml` 的值里，也不烤进镜像。

`home/` 是**声明层**，`/state` 是**运行层**，启动时声明层投影进运行层，规则三条：

- 声明的文件赢。改了部署仓库里的 kubeconfig，重发即生效；工具自己回写到同名文件的改动（`aws configure`、`gh auth`）重启即被覆盖，容器里没有第二处真相。
- 没声明的不动。`known_hosts`、会话、工具缓存、以及 agent 在 `~` 下自己生成的东西全部保留，所以不能整挂宿主目录替代它：只读挂 ssh 写不了 `known_hosts`，可写挂就没有真相。
- 权限进容器时统一：文件 `0600`、目录 `0700`、属主容器用户，宿主侧是什么模式无所谓，ssh 对宽松权限的拒绝不会再出现。

`~` 下哪个是文件哪个是目录由工具决定，`home/` 只是照抄：`.ssh/` 是目录，里面 `config` 加 N 把私钥；`.kube/config` 是一个文件；`.volcengine/` 整个目录。多一把私钥就是多一个文件加 `.ssh/config` 里一段 `Host`。这个模式与 k8s 用 init container 把 Secret 投进家目录、dotfiles 工具把仓库同步进 `~` 相同。`/agent/<name>` 单文件挂法仍能用（`config.toml`、`skills-lock.json` 就是），但文件型凭据不再这样放。

## 2. 映射表

| 工具 | 容器内默认位置 | 认的环境变量 | 推荐通道 | 密级 |
|---|---|---|---|---|
| Claude Code | 可变状态 `/state/.claude/`、`/state/.claude.json`；只读托管层 `/etc/claude-code/`（settings、CLAUDE.md、skills） | `ANTHROPIC_BASE_URL`、`ANTHROPIC_AUTH_TOKEN`、`ANTHROPIC_MODEL` 与 `ANTHROPIC_DEFAULT_*_MODEL`、`CLAUDE_CODE_SUBAGENT_MODEL`、`CLAUDE_CODE_AUTO_COMPACT_WINDOW` | 凭据走环境变量（模板已写）；技能与策略挂 `/etc/claude-code:ro`（[SKILLS](SKILLS.md)） | token S0/S1 |
| cc-connect | `/state/.cc-connect/`（data-dir、`run/api.sock`）、锁文件 `/agent/.config.toml.lock` | 由 `config.toml` 驱动 | `config.toml` 占位符 | 平台密钥 S0 |
| git | `/state/.gitconfig`、`/state/.ssh/{config,known_hosts,id_*}` | `GIT_AUTHOR_NAME` 等 | `home/.ssh/<key>` 加 `home/.ssh/config`（`Host` 段写 `IdentityFile ~/.ssh/<key>`、`IdentitiesOnly yes`）；`.gitconfig` 可声明也可落 state，`known_hosts` 只落 state | 私钥 S1 |
| gh | `/state/.config/gh/hosts.yml` | `GH_TOKEN`、`GH_HOST` | 环境变量 | S1 |
| glab | `/state/.config/glab-cli/config.yml` | `GITLAB_TOKEN`、`GITLAB_HOST` | 环境变量 | S1 |
| kubectl / helmfile | `/state/.kube/config` | `KUBECONFIG` | `home/.kube/config`；多集群多份文件时在 env 里用 `KUBECONFIG` 列 `~/.kube/` 下的路径 | S0（集群 admin）或 S1 |
| helm | 仓库列表 `/state/.config/helm/repositories.yaml`；registry 登录 `/state/.config/helm/registry/config.json`；插件 `/opt/helm/plugins`（镜像内） | `HELM_CONFIG_HOME`（已设）、`HELM_REGISTRY_CONFIG` | 私有 chart 仓库凭据放 `home/.config/helm/registry/config.json`，不需要 `HELM_REGISTRY_CONFIG` | S1 |
| aws | `/state/.aws/{config,credentials}` | `AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY`、`AWS_DEFAULT_REGION`、`AWS_PROFILE` | 环境变量 | S0/S1 |
| aliyun | `/state/.aliyun/config.json` | `ALIBABA_CLOUD_ACCESS_KEY_ID`、`ALIBABA_CLOUD_ACCESS_KEY_SECRET`、`ALIBABA_CLOUD_REGION_ID` | 环境变量 | S0/S1 |
| ve（火山引擎） | `/state/.volcengine/config.json`（路径不可改） | `VOLCENGINE_ACCESS_KEY`、`VOLCENGINE_SECRET_KEY`、`VOLCENGINE_REGION`、`VOLCENGINE_PROFILE`、`VOLCENGINE_DISABLE_DEFAULT_CREDENTIALS` | 环境变量；多账号时 profile 文件放 `home/.volcengine/config.json`（[CLOUD_ACCOUNTS](CLOUD_ACCOUNTS.md)） | S0/S1 |
| tccli（腾讯云） | `/state/.tccli/<profile>.configure`、`<profile>.credential` | `TENCENTCLOUD_SECRET_ID`、`TENCENTCLOUD_SECRET_KEY`、`TENCENTCLOUD_REGION`、`TENCENTCLOUD_TOKEN`、`TCCLI_PROFILE`（优先级：命令行 > 文件 > 环境变量） | 环境变量；多账号时 profile 文件放 `home/.tccli/` | S0/S1 |
| cloudflared | `/state/.cloudflared/`（cert、tunnel 凭据） | `TUNNEL_TOKEN` | 环境变量（tunnel token） | S1 |
| npm | `/state/.npmrc` | `npm_config_registry`、`npm_config_disturl`（cn profile 已设）、`NPM_CONFIG_USERCONFIG` | 私有源 token 放 `home/.npmrc`，不需要 `NPM_CONFIG_USERCONFIG` | S1 |
| go | 无家目录配置 | `GOPROXY`、`GOSUMDB`（profile 已设）、`GOPRIVATE`、`GONOSUMDB` | 私有模块走 `GOPRIVATE`，认证靠 git 的 SSH 身份 | S2 |
| pip / uv | `/state/.config/pip/pip.conf`、`/state/.config/uv/uv.toml` | `PIP_INDEX_URL`、`UV_DEFAULT_INDEX`、`HF_ENDPOINT`（cn profile 已设） | 环境变量 | S1（带凭据时） |
| mise | `/etc/mise/`（镜像内只读）、`/state/.local/state/mise/` | 运行期已锁死离线，不接受实例配置 | 无需配置 | 无 |

密级定义见 [SECRETS](SECRETS.md) §1。凡是工具自己会把 token 写回家目录的（gh、glab、aws、aliyun、helm registry），state 卷就是密钥载体，备份与销毁按 S1 处理。

## 3. compose 写法

```yaml
services:
  demo:
    env_file: [./examples/demo/env]             # 环境变量型凭据
    volumes:
      - ./examples/demo/config.toml:/agent/config.toml:ro
      - ./examples/demo/home:/agent/home:ro                   # 文件型凭据：home/.ssh/、home/.kube/……
      - demo-state:/state
      - demo-cache:/cache
```

```toml
# config.toml：把变量注入 agent 子进程。密钥只写占位符；文件型凭据在 home/ 里，这里不需要指路
[projects.agent.options.env]
GH_TOKEN = "${GH_TOKEN}"
AWS_ACCESS_KEY_ID = "${AWS_ACCESS_KEY_ID}"
AWS_SECRET_ACCESS_KEY = "${AWS_SECRET_ACCESS_KEY}"
```

`home/` 里的文件宿主侧 `0600`、属主与容器 `AGENT_UID` 一致（`deploy` 落地时自动做），否则容器内读不到。改凭据只需替换文件后重建容器，state 卷不用动。

## 3a. 先验证网关再起实例

网关地址或 key 不对时 Claude Code 不会报错退出，而是无输出挂住，表现为机器人收到消息后没有任何回复。起实例前在容器里用 curl 直接打一次（`ANTHROPIC_MODEL` 需已在 env 里设置，网关侧的模型名没有可靠默认值）：

```bash
docker compose exec -T demo sh -c 'curl -sS -m 20 "$ANTHROPIC_BASE_URL/v1/messages" \
  -H "x-api-key: $ANTHROPIC_AUTH_TOKEN" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
  -d "{\"model\":\"${ANTHROPIC_MODEL}\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}"'
```

返回 `content` 才算通；`401`/`403` 是 key 与该主机不匹配（阿里云百炼的 key 按区域和产品线分主机，同一把 key 只对一个主机有效）。手工测 `claude -p` 时要加 `</dev/null`：非终端 stdin 下它会一直等 EOF。

## 4. 加一个工具时补这张表

进镜像的工具在 `mise.toml` 加声明（见 [TOOLCHAIN](TOOLCHAIN.md) §4）后，在本表加一行：默认位置、认的变量、推荐通道、密级。没有这一行，部署者就得自己去查。
