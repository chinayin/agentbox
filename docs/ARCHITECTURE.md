# 架构与挂载契约

> 契约。agentbox 的产出不是 Dockerfile，而是一份**挂载契约**：固定路径 + 环境变量。镜像和 compose 模板只是实现，换编排器（compose / k8s / 裸 `docker run`）不改镜像。为什么这样设计见 [DECISIONS](DECISIONS.md)。

## 1. 三条原则

1. **镜像不含身份。** 只有工具链，没有配置、密钥、仓库。同一镜像跑任何 project，换 project 只换挂载。看似无害的默认值也算身份。
2. **实例完全由挂载描述。** 一个实例 = 一组挂载 + 一份 env，没有第二处真相。不允许"先进容器手工跑一下"的步骤，必需的初始化只能在镜像、entrypoint 或挂载数据里。
3. **谁都不需要 docker 权限。** 不挂 docker socket。docker 组成员等价于免密 root。

## 2. 挂载契约

路径表见 [README](../README.md#挂载契约)，与 `entrypoint.sh --help` 由 `scripts/test.sh` 保持一致。三处设计意图：

**`HOME=/state` 是拱心石。** agent CLI 与桥接器的状态自动归到一个挂载点（`.claude/`、`.pi/`、`.cc-connect/`、`.ssh/`、`.gitconfig`），备份、迁移、销毁都是对单个卷的操作。cc-connect 的排他锁在配置文件旁（`/agent/.config.toml.lock`），所以 `/agent` 目录归 agent 用户可写，配置文件本身仍 `:ro`。

**`/agent/home` 是 HOME 的声明层。** 实例目录带一个照 `~` 结构摆的 `home/`，只读挂进来，entrypoint 每次启动复制进 `/state`：声明的文件赢，没声明的不动。规则、映射与为什么不直接挂宿主目录，见 [CREDENTIALS](CREDENTIALS.md) §2。

**缓存必须显式外迁出 HOME**，否则 state 卷会堆进几个 G 的垃圾：`npm_config_cache`、`GOMODCACHE`、`GOCACHE`、`XDG_CACHE_HOME`、`HELM_CACHE_HOME` 全指向 `/cache`。`/cache` 每信任域一个 named volume，同容器多 project 共用（go/npm 自带文件锁），跨信任域不共享，否则一个域被投毒的包会进入另一个域。

## 3. 六类数据，六种生命周期

| 数据 | 生命周期 | 载体 | 丢失后果 |
|---|---|---|---|
| 工具链 | 随镜像版本 | 镜像层 | 重拉镜像 |
| 实例声明 | 随配置变更，进 git | bind mount `:ro` | 从配置仓恢复 |
| 密钥 | 随轮换 | `env_file`；文件型走 `home/` → `/agent/home` `:ro` | 重新下发 |
| 工作区 | 长期，宿主为真相 | **bind mount 宿主目录** | **不可恢复** |
| 会话状态 | 中期，可丢 | named volume | 丢历史 |
| 缓存 | 随时可丢 | 每信任域一个 named volume | 变慢 |

只有工作区不可恢复，所以它必须是 bind mount，不能是 named volume。

## 4. 一套公共工具链，每个 agent 一个变体

工具链只有一层：`agentbox:<版本>` 装 Claude Code，`-pi` 装 pi，两者从同一个不含 agent 的基础阶段分出，互不包含；再加一个 agent 就是一份 `mise.<agent>.toml` 覆盖层加一个构建阶段。组成与版本策略见 [TOOLCHAIN](TOOLCHAIN.md)。

工具由 `mise install --system` 装到 `/usr/local/share/mise`，运行期从 system shims 找，不依赖 shell profile，也不会被 `HOME=/state` 覆盖。构建永远直连上游、不分境内外；运行期用不用境内源由 `AGENTBOX_PROFILE` 决定，见 [CN_MIRRORS](CN_MIRRORS.md)。

选哪个 agent CLI 是运行期决定的（`config.toml` 的 `agent.type`），声明了 pi 就必须用 `-pi` 变体镜像。pi 会话端到端尚未用真实凭据验证（[ROADMAP](ROADMAP.md) 第 7 行）。

## 5. 构建期 / 运行期陷阱

根因相同：容器的构建期和运行期看到的文件系统不是同一个。每条都有 `scripts/test.sh` 的断言对应。

| 陷阱 | 现象 | 做法 |
|---|---|---|
| 构建期向 HOME 写东西 | `HOME=/state` 运行期被卷整个盖掉：`go env -w`、`helm plugin install`、user scope 的 mise 安装全部失效 | `ENV GOPROXY=`；`HELM_PLUGINS=/opt/helm/plugins`；`mise install --system`；构建缓存只用 `/tmp/mise-cache` 并在层内清掉 |
| 非交互 shell 读不到 profile | agent 是 fork 出来的子进程，不读 `/etc/profile.d`、`~/.bashrc` | 环境变量只走 `env_file` + 占位符；二进制在镜像 `ENV PATH` 里；验证用 `docker compose exec <svc> command -v go`，不要先进容器再敲 |
| UID 不一致 | bind mount 不做 UID 映射，容器写不进工作区 | 构建时 `--build-arg AGENT_UID=`（`make image AGENT_UID=`）与宿主工作区属主对齐；发布到 GHCR 的镜像固定 1000，属主不同就本地重建 |
| Dockerfile 的 ENV 不能条件分支 | 境内源默认值无法按运行环境切换 | 境内源写成仓库文件 `etc/agentbox/profiles/cn.env` 随镜像带入，entrypoint 在 `AGENTBOX_PROFILE=cn` 时只对未设置的变量导出 |
| mise shim 按 cwd 找配置 | 被托管仓库自带 `mise.toml` 会让 node/go 去找仓库要的版本，离线下失败 | `MISE_IGNORED_CONFIG_PATHS=/workspace:/cache:/refs:/knowledge:/opt/toolkit`；`/state` 不能放进去（会连系统配置一起丢），HOME 下的 mise 配置由 `MISE_GLOBAL_CONFIG_FILE=/etc/mise/config.toml` 封住 |
| locked mode 靠构建参数 | `MISE_LOCKED=1` 可被绕过 | `mise.toml` 的 `[tool_config] locked = true` 随 lock 入仓；Dockerfile 只跑无参数的 `mise install --system` |
| 运行期联网补装 | 持有实例密钥时临时联网 | `MISE_OFFLINE=true`、`MISE_NOT_FOUND_AUTO_INSTALL=false`、`MISE_NOT_FOUND_SYSTEM_FALLBACK=false`，缺工具直接失败 |
| 嵌套挂进 `/state` | docker 以 root 创建嵌套挂载点，`/state/.claude` 之类变成 root 属主，agent 写不进会话状态 | 不在 state 卷内部再挂任何东西；文件型凭据走 `/agent/home`，技能走 `/etc/claude-code` |

**代理：`NO_PROXY` 要同时写 CIDR 与单 IP。** Go 系工具认 CIDR，curl 不认。内网目标既写 CIDR 又单列精确 IP。agent 会自己拼代理行，靠两层挡：`config.toml` 的 `[projects.agent.options.env]` 固化 `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY`，系统提示里写明"代理已配置，勿自创"。不要放 `/etc/environment`，agent 不是登录会话读不到。

## 6. entrypoint：把挂载投影成运行环境，然后 exec 桥接器

顺序固定四步，全部只读 `:ro` 路径、只写 `/state`，之后 `exec cc-connect`。不重启、不守护（那是编排器的事）。

1. **profile 默认值**：`AGENTBOX_PROFILE=cn` 时逐行导出 `/etc/agentbox/profiles/cn.env`，只填未设置的变量。
2. **前置检查**，失败 `exit 2` 且一次性列全。只有三项，都是 cc-connect 管不到或报不清的：配置文件挂了没、HOME 可写吗、配置里引用的 `${占位符}` 都有值吗。配置结构本身的对错不在这里复刻 cc-connect 的 schema，让它自己报；工具装没装由 smoke 按 lock 逐项验，运行期不再查。
3. **home 层投影**：`/agent/home` 存在时把它复制进 `/state`，文件 `0600`、目录 `0700`，声明的文件赢、其余不动。
4. **按清单装技能**：`/agent/skills-lock.json` 里列的、`/state` 里还没有的，用 `npx skills add` 装进去。任何失败只 `Warning:` 并留 `/state/.agents/.agentbox-skills-missing` 标记，技能装不上 agent 也要能收消息（[SKILLS](SKILLS.md) §3）。

第一个参数不以 `-` 开头时是命令模式：跳过以上全部直接 `exec`，给调试用。镜像里只有这一个脚本，`/entrypoint.sh`。

## 7. 明确不做

| 不做 | 理由 |
|---|---|
| 控制平面 / API / Web UI | 桥接器自带，加一层是负债 |
| 每任务起一个容器、agent 自己管容器 | 要交 docker socket，破隔离 |
| 内置任何具体项目的配置 | 违反原则 1 |
| 宿主 systemd 托管 | 编排器已有重启语义，两套会互相覆盖 |
| 在 compose 里配日志轮转 | 轮转是宿主 `daemon.json` 的职责。**部署方必须自行确认宿主已配**，json-file 驱动默认不轮转 |
| 宿主机引导脚本 | 部署方职责 |

## 8. 规模化

契约只是路径 + 环境变量，单机 compose 到 k8s Deployment（一信任域一 Deployment）不改镜像。要做会话多路复用的专用运行时，先把执行层换成 ACP 之类可远程调度的形态。
