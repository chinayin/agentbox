# 决策与实测记录

> 记录，只增不改。每条写日期（早期未记日期的标 —）、决定、依据。契约文件（ARCHITECTURE、TOOLCHAIN、CREDENTIALS、INSTANCES、SKILLS）只写现状，为什么这样在这里。要推翻某条，加一条新的，不改旧的。

## 已否决

| 日期 | 否决 | 依据 |
|---|---|---|
| — | agent CLI 走 sidecar | 桥接器是 fork/exec 本地子进程，agent CLI 必须同容器。唯一解耦口子是 ACP，本项目不做但不堵 |
| — | 给容器挂 docker socket；每任务起一个容器、agent 自己管容器 | docker 组成员等价于免密 root，破隔离 |
| — | `/mise` 单目录模式安装 mise | 与 system scope 冲突 |
| — | 用 npm 安装 cc-connect | npm 包只是无校验的下载器，从同一 GitHub release 拉包 |
| — | `base/go/k8s/full` tag 矩阵与 `-cn` tag | 收敛为单镜像 + pi 变体，境内外同 tag |
| 2026-09-06 | 构建期境内镜像分支（`PROFILE=cn`） | 正式镜像只由境外 CI 构建，lock 保证字节一致，构建地点不是产物的维度；境内构建机用 docker 代理构建参数即可。从未跑通过，已删 |
| 2026-09-06 | 给容器设内存 / CPU 硬上限 | 单机常见 2c4g，硬上限会让先撞到的实例被 OOM kill，而 agent 负载是突发式的。pids 保留 |
| 2026-09-06 | 按信任域切分网络 | 所有容器共用一张宿主级 `agentbox` 网络，换取多 compose 工程可合并；隔离退回到 `env_file` 与卷 |
| — | egress 代理 sidecar | 超出本仓库范围，先 spike 再立项 |
| — | 在 compose 里配日志轮转 | 轮转策略是宿主 `daemon.json` 的职责，每个 service 重复 `log-opts` 会和宿主配置打架，漏配一个就无声失效 |
| — | 宿主机引导脚本（装 docker、写 daemon.json、建工作区） | 部署方职责，不在镜像仓库范围；仓库里原来的 host-bootstrap 脚本已删除 |
| — | yamllint | 只有 pipx backend。2026-09-21 tccli 走 `pipx:` 之后「锁不到 URL」不再是一票否决，但没有任何技能或脚本依赖它，`yamlfmt` 已覆盖格式检查 |
| 2026-09-09 | 发布 `linux/arm64` | 加上 arm64 后 publish 从 2m12s 变 7m50s（334s 是 QEMU 里的 apt 层），缓存包从 776 MB 到 1523 MB，而 arm64 没有部署目标。`v0.3.0` 含 arm64 层可供开发机拉取，但从未运行过。重开需先有真实 arm64 部署目标 |
| 2026-09-09 | 构建缓存用 `type=gha` | Actions 缓存作用域是「写入它的 ref 加默认分支」，tag 触发的 run 写进去的缓存下一个 tag 读不到；`v0.1.0` 因此白传 1.59 GB。改用 registry 后端 `ghcr.io/<repo>-buildcache:shared` 单 ref |
| 2026-09-11 | 用 `npx skills experimental_install` 按 lock 还原技能 | 实测它把技能写进 `<项目>/.agents/skills/` 却不建 `.claude/skills/`，Claude Code 看不见；`experimental_sync` 只扫 node_modules。所以 entrypoint 逐条 `skills add`。上游补全后可换回 |
| — | 部署仓库用 sops/age 加密 `env` | 明文提交换来克隆即可用、diff 直接可读、不引入加密工具链；代价是仓库泄露后只能全量轮换。仓库权限是唯一防线 |
| 2026-09-11 | 镜像或部署仓库带 fleet 级默认技能清单 | 镜像不含身份；部署仓库里也不继承，一个实例要么自己写上，要么就没有 |
| 2026-09-21 | 文件型凭据以 `/agent/<文件>:ro` 单挂 | 改为实例目录 `home/` 整目录挂 `/agent/home`，entrypoint 复制进 `/state`。原因：整挂宿主目录只读则工具写不了，可写则配置没有真相；单文件挂法每加一个凭据都要改 compose 与指路变量 |

## 实测数字

| 日期 | 环境 | 结论 |
|---|---|---|
| 2026-09-05 | 阿里云香港 x86_64 | 直连上游完整构建 + smoke 通过 |
| 2026-09-06 | 开发机 | 运行期 `cn.env` 各地址可达性均 200：mirrors.aliyun.com/pypi、registry.npmmirror.com、npmmirror.com/mirrors/node（含 headers 包）、hf-mirror.com、goproxy.cn；阿里云 goproxy 响应约 8 秒，故放后备位 |
| 2026-09-06 | 内网目标 | `NO_PROXY` 漏写精确 IP 时 curl 走代理：直连 9ms vs 走代理 481ms，表现是"某些命令慢得离谱但都成功" |
| 2026-09-08 | GitHub Actions | `v0.1.0` 首次 tag 因并发组死锁失败：`release.yml` 以 `workflow_call` 调 `ci.yml`，两者并发组同名互等。修复后 `ci.yml` 的并发组带 `pull_request.number || github.ref` |
| 2026-09-09 | GitHub Actions | `v0.2.0` amd64-only publish：冷缓存 2m12s、暖缓存 1m17s，缓存包 776 MB / 14 层，导出 16s。`v0.1.0`（含模拟 arm64、缓存无效）是 13m30s。`GITHUB_TOKEN` 能创建 `-buildcache` 新包，`image-manifest=true` 被 GHCR 接受 |
| 2026-09-09 | GitHub Packages | private 包共用账户配额（Pro 2 GB），缓存包与镜像包各约 1.5 GB 会顶到上限；超额写入被拒而 `cache-to` 的 `ignore-error=true` 会让它变成静默空操作。因此缓存只在仓库 public 时启用，`release.yml` 读 `github.event.repository.private` 决定 |
| 2026-09-10 | 构建机 hk-build | 匿名 `docker pull ghcr.io/chinayin/agentbox:0.3.0` 成功；`docker inspect` 实测 `PidsLimit=512 CapDrop=[ALL] SecurityOpt=[no-new-privileges:true] Init=true` |
| 2026-09-11 | 构建机 | 容器内 `npx skills add <src> -g -s <name> -a claude-code -y` 装进 `/state/.claude/skills/<name>`（实体目录），lock 落 `/state/.agents/.skill-lock.json`；pi 的 global 落点是 `/state/.pi/agent/skills/<name>` |
| 2026-09-13 | cc-connect 源码 757b4df | `relay send --data-dir` 指向对端 socket 只会得到 `target engine not found`：目标必须是同一进程里的 project。跨容器只剩 Management API / Webhook 两个 TCP 入口，都要活的 `session_key` |
| 2026-09-14 | GitHub Actions | `lock.yml` 定时跑出 diff、开 PR #1；GITHUB_TOKEN 开的 PR 产生一次 `pull_request` 运行，但一个 job 都不起直接 failure（2026-09-21 再推一次是 `action_required`），是 GitHub 对 bot 触发的递归保护；`gh workflow run ci.yml --ref` 补跑两段全绿 |
| 2026-09-21 | devops-agent（北京 ECS，20G 盘） | `pipx:tccli` venv 330 MB，是镜像里最大的单个工具。docker 走 containerd 存储时一个 3.5G 镜像实际占约 4.8G，20G 盘放不下两个版本，升级要先 down、`image rm` 旧 tag 再拉。GHCR 从北京拉 900MB 压缩层 25 分钟以上 |
| 2026-09-21 | devops-agent | 两个真实实例 `docker inspect`：pids、cap_drop、no-new-privileges、init 全部生效；home 层 `home/.ssh/{config,key}` 复制进 `/state` 后 git 直连 GitLab 成功 |
| 2026-09-21 | devops-agent | 境内主机上两个实例静默用了上游源：部署链路里没有任何一处携带 `AGENTBOX_PROFILE`，entrypoint 对缺失或未知的 profile 只警告不报错。此后 profile 定为主机属性，写在 `host.env`，由 deploy 派生进每个实例的 `.env`，compose 共享块用 `environment:` 接进容器，`plan` 拒绝非 cn/global 的值与缺该行的 compose |
| 2026-09-21 | cc-connect v1.5.0 源码 | 健康检查只能做 liveness：`api.sock`（`core/api.go`）无鉴权但没有 health 路由，`GET /sessions` 是最便宜的存活探针；Management API 的 `/status` 里 `connected_platforms` 只是配置里的平台名且响应体带 token，不能当探针；飞书 websocket 断开进程不退出（`platform/feishu/feishu.go` 只记一条 `websocket error`），凭据无效时 SDK 直接放弃不重连、进程静默存活，网络故障时每 2 分钟无限重连。所以共享块的 healthcheck 探 `curl --unix-socket /state/.cc-connect/run/api.sock /sessions`，平台在线状态留给上游 |
| 2026-09-21 | devops-agent | 三个实例带 liveness healthcheck 重建，`docker compose ps` 在启动后 30 秒内全部 `(healthy)`，飞书 websocket 同时 connected；探针跑在容器用户下，`api.sock` 0600 归同一用户，无权限问题 |
| 2026-09-21 | deploy | multicloud 的 `CLAUDE.md` 与四个 subagent 文件原放 `workspace-init/`，改了提示词 deploy 后服务器上仍是旧文件：`--ignore-existing` 对运维声明的文件是错的语义。否决了在服务器留上次种子清单做三方比较（多一份状态还要处理冲突）与 entrypoint 每次启动复制（要发新镜像），改为按所有权分目录：`workspace/` 每次覆盖、`workspace-init/` 只种一次，只改 deploy.sh |
| 2026-09-21 | devops-agent | multicloud 首次 `up`：home 层 6 个文件复制进 `/state`，`aws sts get-caller-identity --profile` 回正确账号、不带 `--profile` 报 NoCredentials，`/state/.aliyun` 可写。阿里云 CLI 3.5.0 对 `current` 指向不存在的 profile 直接拒绝所有命令（本机 3.4.10 放过，所以 `verify-profiles.sh` 此前全 PASS）；`current` 指向空 AK 的哨兵 profile 后 `--profile` 正常、不带则报凭据未配置 |
