# 未完成事项

按优先级排列，每项写现状与验收，做完直接删行。

## P1 需要真实环境收口

| # | 事项 | 现状 | 验收 |
|---|---|---|---|
| 1 | `linux/arm64` 镜像在 arm64 上跑通 | 2026-09-09 这个开关翻了三次，最后按实测数据定为**关闭**：amd64 单架构 publish 冷 2m12s、暖 1m17s，加上 arm64 要 7m50s（其中 334s 是模拟的 apt 层），缓存包也从 776 MB 翻到 1523 MB，而 arm64 没有部署目标——开发机可以拉保留下来的 `v0.3.0`（它含 arm64 层），或本地 `make image` 原生构建。**`v0.3.0` 的 arm64 层仍然从未被运行过**：在 QEMU 里构建成功不等于能跑 | 在 Apple Silicon 上 `docker run ghcr.io/<repo>:0.3.0 --version` 成功（会自动选 arm64 manifest）；重开发布则需先有真实 arm64 部署目标 |
| 2 | `relay send --data-dir` 跨容器 | `MULTI_PROJECT.md` §3 的"挂对端 socket"建立在未验证前提上 | 两容器实验；不通就把该行改为"不可行" |
| 3 | CI 首跑 | 2026-09-07 推送到 GitHub 私有仓库，main 上 `ci.yml` 两段已绿；2026-09-08 `v0.1.0` 跑通了 tag 这条（第一次因并发组死锁失败，修复见第 4 行）。PR 与 `lock.yml` 两条仍未跑过 | 推送后首个 PR 两段全绿；`lock.yml` 手动触发能开 PR，且 PR 分支上出现由 dispatch 触发的 ci 运行 |
| 4 | GHCR 镜像被服务器拉取 | 2026-09-09 `v0.2.0` 已发布并**验证过匿名可拉**（仓库与包当前 public，`ghcr.io/v2/.../tags/list` 无凭据可读，manifest 只含 amd64）。发布链路本身已验证：bake `--push`、registry 缓存、amd64-only 三条都跑通。**但仍没有服务器真的拉过**，且若转为 private，服务器会重新需要一个带 `read:packages` 的 PAT 做 `docker login ghcr.io`——这是人工步骤，deploy 技能不得自动化。2026-09-09 起由 litellm-gateway 迁移 demo 收口：构建机作为第一个 deploy 目标拉 `v0.2.0` | 目标主机上 `docker pull` 两个镜像成功 |
| 5 | `deploy` 技能真实主机首跑 | 技能与文档已实现（`.claude/skills/deploy/`），本地测试通过，但从未连过真实主机；依赖上一行先跑通，否则服务器上没有版本可拉。同一 demo 收口 | 在真实主机上 `plan` 与 `deploy` 各跑通一次，且 `status` 能看到容器 running |
| 5a | `import-instance` 真实源首跑 | 2026-09-10 对真实源 ECS 跑通了 `plan` 与 `import`（只读），产物通过 `deploy plan` 离线校验并已提交部署仓库；尚未在构建机起来。两处阻塞：源实例的 `ANTHROPIC_BASE_URL` 是 VPC 内网地址，构建机不可达，需要可达的网关或把 demo 放进 VPC；飞书 demo 应用的 id/secret 与 open_id 由用户填写后才能 `deploy`。 | 对 litellm-gateway 源实例 `plan` 与 `import` 各跑通一次，产物经 `deploy plan` 校验通过，并在构建机上起来 |

## P2 加固

| # | 事项 | 现状 | 验收 |
|---|---|---|---|
| 6 | compose 加固：`read_only: true` + tmpfs + healthcheck | 未做；`cap_drop`、`no-new-privileges`、`init`、pids 上限已有，但**这一层完全没有测试覆盖**——`make smoke` 走裸 `docker run`，不经过 compose。cc-connect 凭据无效时不退出只刷 websocket error，healthcheck 不能只看进程 | 起真实实例后 `docker inspect` 能读到 `PidsLimit`、`CapDrop`、`SecurityOpt` 实际生效（`docker compose config` 只证明 YAML 没写错，不算验收）；实例 `healthy` 且无 `read-only file system` |
| 7 | pi 会话端到端 | 已决定（2026-09-06）：pi 变体保留；2026-09-07 起与 Claude Code 镜像平级、共享工具链、互不包含。先把 Claude Code 生态跑通，pi 之后再验证。`agent.type = "pi"` 已被接受并启动引擎，未用真实凭据驱动过会话 | 真实飞书应用 + `-pi` 镜像，发一条消息拿到回复 |
| 8 | state 卷备份/恢复脚本 | 无脚本；卷内含 git 私钥 | `scripts/state-backup.sh`，文档标注备份件密级 |

## 已否决

- egress 代理 sidecar：超出本仓库范围，先 spike 再立项。
- `base/go/k8s/full` tag 矩阵与 `-cn` tag：已收敛为单镜像 + pi 变体，境内外同 tag。
- `/mise` 单目录模式安装 mise：与 system scope 冲突。
- 给容器挂 docker socket。
- 用 npm 安装 cc-connect：npm 包只是无校验的下载器，从同一 GitHub release 拉包。
- yamllint：只有 pipx backend，锁不到 URL/SHA256。
- 宿主机引导脚本（装 docker、写 daemon.json、建工作区）：属于部署方职责，不在镜像仓库范围；`scripts/host-bootstrap.sh` 已删除。
- 给容器设内存 / CPU 硬上限：2026-09-06 决定不设。单机常见 2c4g，硬上限会让先撞到的实例被 OOM kill，而 agent 负载是突发式的。pids 保留，理由见 `docs/MULTI_PROJECT.md` §6。
- 按信任域切分网络：2026-09-06 决定所有 agentbox 容器共用一张宿主级 `agentbox` 网络，换取多 compose 工程可合并。隔离退回到 `env_file` 与卷这一层，见 `docs/SECRETS.md` §3。
- 构建期境内镜像分支（`PROFILE=cn`）：正式镜像只由境外 CI 构建，lock 保证字节一致，构建地点不是产物的维度；境内构建机用 docker 代理构建参数即可。2026-09-06 删除，从未跑通过。
