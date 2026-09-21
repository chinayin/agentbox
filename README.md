# agentbox

挂载驱动的 AI agent 运行时镜像：聊天平台桥接器（cc-connect）+ 编码 agent CLI（Claude Code / pi）+ 工具链装进一个镜像，实例只由挂载和环境变量描述。宿主机只需要 docker。

三条不可妥协的原则：**镜像不含身份、实例完全由挂载描述、谁都不需要 docker 权限。** 详见 [ARCHITECTURE](docs/ARCHITECTURE.md)。

## 快速开始

```bash
make image                                                        # agentbox:dev 与 agentbox:dev-pi
docker network create agentbox                                    # 一次性；compose 声明为 external
cp .env.example .env
cp examples/demo/env.example examples/demo/env && chmod 600 examples/demo/env
mkdir -p runtime/workspaces/demo                                  # 属主须与镜像 AGENT_UID（默认 1000）一致
docker compose up -d
```

## 挂载契约

| 容器内路径 | 模式 | 内容 | 必需 |
|---|---|---|---|
| `/agent/config.toml` | ro | 实例声明，只含 `${占位符}`，可进 git | 是 |
| `/agent/skills-lock.json` | ro | 技能清单（`npx skills add` 生成的 lock，原样用），列出的技能首次启动时装进 `/state`，见 [SKILLS](docs/SKILLS.md) | 否 |
| `/agent/home` | ro | 家目录声明层：目录结构照 `~` 摆，每次启动复制进 `/state`，声明的文件赢、其余不动，见 [CREDENTIALS](docs/CREDENTIALS.md) §2 | 否 |
| `/workspace` | rw | 工作区，宿主目录 bind mount | 是 |
| `/state` | rw | 会话与身份状态，`HOME` 指向此 | 是 |
| `/cache` | rw | 构建缓存，每信任域独占 | 建议 |
| `/opt/toolkit` | ro | 共享脚本库，`bin/` 已在 PATH | 否 |
| `/etc/claude-code` | ro | Claude Code 托管层：`managed-settings.json`、`CLAUDE.md`、`.claude/skills/`，见 [SKILLS](docs/SKILLS.md) | 否 |
| `/refs/<name>` | ro | 只读引用别的工作区 | 否 |
| `/knowledge` | ro | 共享知识库 | 否 |

环境变量型密钥走 `env_file`；kubeconfig、SSH 私钥、云 CLI 配置这类文件型凭据放实例目录的 `home/`，照家目录的结构摆，整目录挂到 `/agent/home`。entrypoint 启动前校验配置文件存在、state 可写、全部占位符有值，缺什么一次性列全后退出 2。本地开发用根目录的这份 compose，发布到服务器走 `deploy` 技能与独立的部署仓库，镜像按版本从 GHCR 拉取。

## 镜像

| tag | 内容 |
|---|---|
| `agentbox:<版本>` | 公共工具链 + Claude Code |
| `agentbox:<版本>-pi` | 公共工具链 + pi，不含 Claude Code |

公共工具链：运行时（Node / Go / Python）、Kubernetes 交付链、云厂商与代码托管 CLI、通用工具、cc-connect。工具清单以 `mise.toml` 与 `mise.claude.toml` / `mise.pi.toml` 为准，精确版本与校验和锁在 lock 文件里，构建只读 lock。用哪个 agent CLI 由 `config.toml` 的 `agent.type` 决定。见 [TOOLCHAIN](docs/TOOLCHAIN.md)。

## 多实例

**实例 = 一个目录 = 一个 compose 项目 = 一个信任域。** 共享密钥的 project 放同一容器，加一个 `[[projects]]` 块；密钥要隔离才开新实例。每个实例目录自带 `docker-compose.yaml`（模板 `examples/demo/docker-compose.yaml`），所有实例共用一张外部 `agentbox` 网络。详见 [INSTANCES](docs/INSTANCES.md)。

## 开发

```bash
make check     # test + lint，不需要 docker、不联网
make image     # 构建两个镜像，agentbox:dev 与 agentbox:dev-pi
make smoke     # 对已构建镜像做运行期验收
make lock      # 升级工具链到上游最新（通常由 CI 的 lock.yml 跑）
```

本地产物统一落 `runtime/`，已被 git 与 docker 忽略。四个 Claude Code 技能都在 `.claude/skills/`：`new-instance` 从模板造实例、`import-instance` 从裸机实例反向导入、`remote-build` 在远端构建镜像、`deploy` 把部署仓库推到主机。

## 文档

`docs/` 分三类，文件开头一行标明。**契约**写现状，必须与代码一致；**记录**只增不改；**设计稿**未实现，不作现状引用。

| 文档 | 类型 | 内容 |
|---|---|---|
| [ARCHITECTURE](docs/ARCHITECTURE.md) | 契约 | 原则、挂载契约、数据生命周期、构建期/运行期陷阱、entrypoint、明确不做的事 |
| [TOOLCHAIN](docs/TOOLCHAIN.md) | 契约 | 工具链组成、版本策略、lock 生成、加工具、CI 与发布 |
| [CREDENTIALS](docs/CREDENTIALS.md) | 契约 | 密级、三条凭据通道、每个工具的凭据位置与变量、红线、泄露应急 |
| [INSTANCES](docs/INSTANCES.md) | 契约 | 信任域切分、实例目录、跨实例调用、网络与资源 |
| [CHANNELS](docs/CHANNELS.md) | 契约 | 飞书、企业微信应用在平台后台要开的权限、事件、回调与凭据变量 |
| [SKILLS](docs/SKILLS.md) | 契约 | 技能清单、托管层、安装 SOP |
| [GIT_IDENTITY](docs/GIT_IDENTITY.md) | 契约 | 机器人 git 身份、权限、可追溯性、密钥轮换 |
| [CN_MIRRORS](docs/CN_MIRRORS.md) | 契约 | 境内运行的镜像源 profile |
| [ROADMAP](docs/ROADMAP.md) | 记录 | 未完成事项，每项带验收 |
| [DECISIONS](docs/DECISIONS.md) | 记录 | 已否决方案与实测数字，带日期 |
| [design/MULTI_CLOUD](docs/design/MULTI_CLOUD.md) | 设计稿 | 多云运维：主 bot 调度各云专才 bot |
| [design/CLOUD_ACCOUNTS](docs/design/CLOUD_ACCOUNTS.md) | 设计稿 | 一家云多个账号的别名、名册与强制层 |

## 参与与许可

干活规则见 [CLAUDE.md](CLAUDE.md)，安全问题报告见 [SECURITY](SECURITY.md)。代码以 [MIT](LICENSE) 许可发布。
