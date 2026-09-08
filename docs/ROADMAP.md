# 未完成事项

按优先级排列，每项写现状与验收，做完直接删行。

## P1 需要真实环境收口

| # | 事项 | 现状 | 验收 |
|---|---|---|---|
| 1 | `linux/arm64` 镜像 | lock 已含双架构 URL，只在 x86_64 真实构建过 | `make image PLATFORM=linux/arm64 && make smoke PLATFORM=linux/arm64` 通过 |
| 2 | `relay send --data-dir` 跨容器 | `MULTI_PROJECT.md` §3 的"挂对端 socket"建立在未验证前提上 | 两容器实验；不通就把该行改为"不可行" |
| 3 | CI 首跑 | 2026-09-07 已推送到 GitHub 私有仓库，main 上 `ci.yml` 两段已绿（首跑暴露的 smoke 清理 uid 问题已修）；PR、tag、`lock.yml` 三条尚未跑过 | 推送后首个 PR 两段全绿；首个 `v*` tag 让 `release.yml` 先跑 ci 再发布；`lock.yml` 手动触发能开 PR，且 PR 分支上出现由 dispatch 触发的 ci 运行 |
| 4 | `v*` tag 发布链路首跑 | 2026-09-08 首次推 `v0.1.0`，`release.yml` 秒失败：被调用的 `ci` job 根本没被创建，run 只有 20 秒、无日志。原因是 `ci.yml` 的并发组用了 `${{ github.workflow }}`，而该上下文在 `workflow_call` 里解析成**调用方**的名字，于是父子两个 run 抢同一个组、死锁。已把两边前缀写死并加 `workflow invariants` 三条断言看住；重推 tag 后的结果尚未确认，GHCR 上仍没有任何 agentbox 镜像 | 两个多架构镜像在 GHCR 上可被服务器拉取 |
| 5 | `deploy` 技能真实主机首跑 | 技能与文档已实现（`.claude/skills/deploy/`），本地测试通过，但从未连过真实主机；依赖上一行先跑通，否则服务器上没有版本可拉 | 在真实主机上 `plan` 与 `deploy` 各跑通一次，且 `status` 能看到容器 running |

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
