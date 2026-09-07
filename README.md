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
| `/agent/config.toml` | ro | 实例声明，只含 `${占位符}`，可进 git。`/agent/` 下可再挂文件型凭据 | 是 |
| `/workspace` | rw | 工作区，宿主目录 bind mount | 是 |
| `/state` | rw | 会话与身份状态，`HOME` 指向此 | 是 |
| `/cache` | rw | 构建缓存，每信任域独占 | 建议 |
| `/opt/toolkit` | ro | 共享脚本库，`bin/` 已在 PATH | 否 |
| `/etc/claude-code` | ro | Claude Code 托管层：`managed-settings.json`、`CLAUDE.md`、`.claude/skills/`，见 [SKILLS](docs/SKILLS.md) | 否 |
| `/refs/<name>` | ro | 只读引用别的工作区 | 否 |
| `/knowledge` | ro | 共享知识库 | 否 |

环境变量型密钥走 `env_file`；kubeconfig、SSH 私钥这类文件型凭据逐个 `:ro` 挂到 `/agent/<name>`，映射见 [TOOLS](docs/TOOLS.md)。entrypoint 启动前校验配置文件存在、state 可写、全部占位符有值，缺什么一次性列全后退出 2；配置结构本身的对错由 cc-connect 报。本地开发用根目录的这份 compose，发布到服务器走 `deploy` 技能与独立的部署仓库，镜像按版本从 GHCR 拉取。

## 镜像

| tag | 内容 |
|---|---|
| `agentbox:<版本>` | 公共工具链 + Claude Code |
| `agentbox:<版本>-pi` | 公共工具链 + pi，不含 Claude Code |

公共工具链：运行时（Node / Go / Python）、Kubernetes 交付链、云厂商与代码托管 CLI、通用工具、cc-connect。两个镜像共享这一层，只在最后一层各装一个 agent CLI；再加 agent 就是多一个 tag。

工具清单以 `mise.toml`（公共工具链）与 `mise.claude.toml` / `mise.pi.toml`（各 agent）为准，精确版本、下载 URL 与上游提供的 SHA256 锁在 lock 文件里，构建只读 lock。用哪个 agent CLI 由 `config.toml` 的 `agent.type` 决定。版本策略、加工具、发布流程见 [TOOLCHAIN](docs/TOOLCHAIN.md)。

## 多实例

**容器边界 = 信任域边界，不是 project 边界。** 共享密钥的 project 放同一容器，加一个 `[[projects]]` 块；密钥要隔离才拆新的 compose service。详见 [MULTI_PROJECT](docs/MULTI_PROJECT.md)。新实例的骨架由 Claude Code 技能 `.claude/skills/new-instance/SKILL.md` 生成，它先问是否共享密钥再决定走哪条路。

## 开发

```bash
make check     # test + lint，不需要 docker、不联网
make image     # 构建两个镜像，agentbox:dev 与 agentbox:dev-pi
make smoke     # 对已构建镜像做运行期验收
make lock      # 升级工具链到上游最新（通常由 CI 的 lock.yml 跑）
```

本地产物统一落 `runtime/`，已被 git 与 docker 忽略。本机网络不适合拉资产时用 remote-build 技能（`.claude/skills/remote-build/SKILL.md`）在远端构建，构建机地址放技能目录下已忽略的 `.env`。

## 文档

| 文档 | 内容 |
|---|---|
| [ARCHITECTURE](docs/ARCHITECTURE.md) | 原则、挂载契约、数据生命周期、构建期/运行期陷阱、明确不做的事 |
| [TOOLCHAIN](docs/TOOLCHAIN.md) | 工具链组成、版本策略、lock 生成、加工具、CI 与发布 |
| [CN_MIRRORS](docs/CN_MIRRORS.md) | 境内构建的三层下载模型 |
| [MULTI_PROJECT](docs/MULTI_PROJECT.md) | 信任域切分、跨实例调用、共享依赖 |
| [SECRETS](docs/SECRETS.md) | 密级模型、占位符机制、红线 |
| [TOOLS](docs/TOOLS.md) | 每个工具的凭据位置、环境变量、推荐提供通道 |
| [SKILLS](docs/SKILLS.md) | 技能与 Claude 全局配置的落法、托管目录、安装 SOP |
| [GIT_IDENTITY](docs/GIT_IDENTITY.md) | 机器人 git 身份：身份方案、权限、可追溯性、密钥轮换 |
| [ROADMAP](docs/ROADMAP.md) | 未完成事项 |

## 参与与许可

干活规则见 [CLAUDE.md](CLAUDE.md)，安全问题报告见 [SECURITY](SECURITY.md)。代码以 [MIT](LICENSE) 许可发布。
