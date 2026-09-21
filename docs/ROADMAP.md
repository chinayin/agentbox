# 未完成事项

按优先级排列，每项写现状与验收，做完直接删行。

## P1 需要真实环境收口

| # | 事项 | 现状 | 验收 |
|---|---|---|---|
| 1 | `linux/arm64` 镜像在 arm64 上跑通 | 2026-09-09 这个开关翻了三次，最后按实测数据定为**关闭**：amd64 单架构 publish 冷 2m12s、暖 1m17s，加上 arm64 要 7m50s（其中 334s 是模拟的 apt 层），缓存包也从 776 MB 翻到 1523 MB，而 arm64 没有部署目标——开发机可以拉保留下来的 `v0.3.0`（它含 arm64 层），或本地 `make image` 原生构建。**`v0.3.0` 的 arm64 层仍然从未被运行过**：在 QEMU 里构建成功不等于能跑 | 在 Apple Silicon 上 `docker run ghcr.io/<repo>:0.3.0 --version` 成功（会自动选 arm64 manifest）；重开发布则需先有真实 arm64 部署目标 |
| 2 | `relay send --data-dir` 跨容器 | 2026-09-13 读 cc-connect 源码（`core/relay.go`，commit 757b4df）：目标必须是**同一进程**里已注册的 engine，挂对端 socket 只会得到 `target engine not found`，"挂对端 socket"这条路按源码判定不可行；跨容器只剩 Management API / Webhook 两个 TCP 入口，且都要活的 `session_key`。仍未实测 | 两容器实验确认报错文案后，把 `MULTI_PROJECT.md` §3 该行改为"不可行" |
| 2a | 多云主 bot 拓扑 A（一实例四 project + relay）跑通 | `docs/MULTI_CLOUD.md` §3 全部基于源码判定：relay 同步、`timeout_secs` 可调、目标会话按来源持久。没有跑过 | 构建机上四个测试飞书应用、一个群 `/bind` 四次，主 bot 对一个跨两家云的问题至少 relay 一次并汇总回人；`visibility = "summary"` 的群内回显符合预期 |
| 2b | 飞书 `include_bot` 权限与 cc-connect 放行 bot @ 消息 | `docs/MULTI_CLOUD.md` §4 依赖两件未验证的事：本租户能否申请 `im:message.group_at_msg.include_bot:readonly`（Lark 国际版文档没有该范围）；cc-connect 接收路径按源码不丢弃 `sender_type = bot` 的 @ 消息，但没有真机跑过，`allow_from` 里 bot open_id 的取值方式也只来自社区 | 两个测试应用互 @ 一次，双方会话都收到；`mention_map` 出站 @ 能触发对方事件 |
| 2d | 多账号名册渲染脚本 | `docs/CLOUD_ACCOUNTS.md` §2 把 `accounts.yaml` 定为唯一真相，要渲染成 AWS `config`、阿里云与火山的 `config.json`、主 bot 名册摘要、钩子白名单四样，脚本未写 | 一份含 aws/aliyun/volc 各一个别名的 YAML 渲染出四样产物，`test.sh` 断言产物里没有 `[default]`、`current` 指向无效 profile、白名单与 YAML 别名一致 |
| 2e | 多账号强制层真机验证 | 部署期校验已做：`verify-profiles.sh` 2026-09-13 对首个实例六个 profile 全 PASS，`test.sh` 有护栏测试。`docs/CLOUD_ACCOUNTS.md` §3、§4 其余五项只到文档或源码层面：阿里云 CLI 在只读 `config.json` 下 STS 续期是否失败（源码显示它会写回）；火山 `ramrolearn` 的会话名与时长参数；托管 `PreToolUse` 钩子在 cc-connect 拉起的 headless 会话里是否拦得住不带 `--profile` 的命令；`sandbox.credentials.envVars` 在 Linux 容器里是否真把 `AWS_PROFILE` 屏蔽；`-admin` 别名命令的权限确认是否送到飞书 | 构建机上一个 AWS 专才挂两个别名：不带 `--profile` 的命令被钩子拒绝且日志有原因；`AWS_PROFILE=x aws ...` 被拒绝；带只读别名的 `get-caller-identity` 回显正确账号；带 `-admin` 别名的写命令在飞书弹出确认 |
| 3 | 人开的 PR 上 `pull_request` 事件的 ci 跑绿 | `lock.yml` 这条 2026-09-14 已闭环：定时跑出 diff、开 PR #1、`gh workflow run ci.yml` 补跑两段全绿、2026-09-18 合并。但 `pull_request` 事件触发的 ci **从未绿过**：GITHUB_TOKEN 开的 PR 会产生一次 `pull_request` 运行，只是一个 job 都不起就以 failure 收场（2026-09-14），再推一次是 `action_required`（2026-09-21）——这是 GitHub 对 bot 触发的递归保护，不是 workflow 写错，`ci.yml` 里 dispatch 那条路就是为此而设。真人开的 PR 还没有过 | 真人开一个 PR，`pull_request` 触发的两段自然绿，不靠 dispatch |

## P2 加固

| # | 事项 | 现状 | 验收 |
|---|---|---|---|
| 6 | compose 加固：`read_only: true` + tmpfs + healthcheck | 已有的一半已验收：2026-09-21 对 devops-agent 上两个真实实例 `docker inspect`，`PidsLimit=512`、`CapDrop=[ALL]`、`SecurityOpt=[no-new-privileges:true]`、`Init=true` 都生效。`read_only` 与 healthcheck 未做；`make smoke` 走裸 `docker run` 不经过 compose，这一层仍只有 `deploy plan` 的文本断言。cc-connect 凭据无效时不退出只刷 websocket error，healthcheck 不能只看进程 | 实例 `healthy` 且日志无 `read-only file system` |
| 7 | pi 会话端到端 | 已决定（2026-09-06）：pi 变体保留；2026-09-07 起与 Claude Code 镜像平级、共享工具链、互不包含。先把 Claude Code 生态跑通，pi 之后再验证。`agent.type = "pi"` 已被接受并启动引擎，未用真实凭据驱动过会话。2026-09-11 起还多一条未验证的：entrypoint 按清单给 pi 装技能时用 `npx skills` 的映射装进 `/state/.pi/agent/skills`（claude 那侧已实测 agent 能列出来），**pi 是否真的从这个目录加载技能没验过** | 真实飞书应用 + `-pi` 镜像，发一条消息拿到回复；同一实例挂一份 `skills-lock.json`，pi 会话里能用上其中的技能 |
| 8 | state 卷备份/恢复脚本 | 无脚本；卷内含 git 私钥 | `scripts/state-backup.sh`，文档标注备份件密级 |
| 9 | home 层落地：所有产出文件型凭据的地方改走 `home/` | 2026-09-21 文件型凭据的标准改为实例目录 `home/` → `/agent/home`（`docs/TOOLS.md` §1）。已按此上线：litellm-gateway（`home/.ssh/{config,key}`）；uufly 已挂 `./home:/agent/home:ro` 并放了占位 `.ssh/config`，四把节点私钥仍在工作区 `secrets/ssh/` 由 `ssh -F` 读，是否迁入待定。仍是旧写法的四处，按依赖顺序：(a) `scaffold.sh --mount kubeconfig/ssh_key` 写 `/agent/<file>:ro` 加 `KUBECONFIG`；(b) `import-instance` 把源主机 `~/.ssh`、`~/.kube` 拆成 `ssh_key`、`kubeconfig-*` 单文件；(c) `verify-profiles.sh` 从 `instances/<n>/profiles/{aws,aliyun,volc,tccli}` 读 profile 文件，`docs/CLOUD_ACCOUNTS.md` §2 的四样渲染产物也按这个目录写；(d) 部署仓库 multicloud 实例（从未启动）的 compose 把 `profiles/*` 直接 `:ro` 挂进 `/state/.aliyun` 等——嵌套挂进 state 卷会让挂载点归 root（`docs/SKILLS.md` §1 的坑），且阿里云 CLI 要写回 `config.json`，`:ro` 下 STS 续期必坏 | (a) `scaffold.sh` 去掉 `--mount`，模板 compose 带 `./home:/agent/home:ro`，凭据由人放进 `home/`；(b) `import-instance` 把源主机家目录里 `.ssh/`、`.kube/` 原样落到 `home/`，不再改写 `KUBECONFIG`；(c) `verify-profiles.sh` 与 CLOUD_ACCOUNTS 改读 `home/.aws/config`、`home/.aliyun/config.json`、`home/.volcengine/config.json`、`home/.tccli/`，`accounts.yaml` 留在 `/agent/accounts.yaml`（名册不是凭据）；(d) multicloud compose 只剩 `./home:/agent/home:ro` 一行，首次 up 前完成；`test.sh` 三组断言随之改写 |

## 已否决

- egress 代理 sidecar：超出本仓库范围，先 spike 再立项。
- `base/go/k8s/full` tag 矩阵与 `-cn` tag：已收敛为单镜像 + pi 变体，境内外同 tag。
- `/mise` 单目录模式安装 mise：与 system scope 冲突。
- 给容器挂 docker socket。
- 用 npm 安装 cc-connect：npm 包只是无校验的下载器，从同一 GitHub release 拉包。
- yamllint：只有 pipx backend。2026-09-21 tccli 走 `pipx:` 之后「锁不到 URL/SHA256」不再是一票否决的理由，但 yamllint 没有任何技能或脚本依赖它，`yamlfmt` 已覆盖格式检查；有真实需求再加。
- 宿主机引导脚本（装 docker、写 daemon.json、建工作区）：属于部署方职责，不在镜像仓库范围；`scripts/host-bootstrap.sh` 已删除。
- 给容器设内存 / CPU 硬上限：2026-09-06 决定不设。单机常见 2c4g，硬上限会让先撞到的实例被 OOM kill，而 agent 负载是突发式的。pids 保留，理由见 `docs/MULTI_PROJECT.md` §6。
- 按信任域切分网络：2026-09-06 决定所有 agentbox 容器共用一张宿主级 `agentbox` 网络，换取多 compose 工程可合并。隔离退回到 `env_file` 与卷这一层，见 `docs/SECRETS.md` §3。
- 构建期境内镜像分支（`PROFILE=cn`）：正式镜像只由境外 CI 构建，lock 保证字节一致，构建地点不是产物的维度；境内构建机用 docker 代理构建参数即可。2026-09-06 删除，从未跑通过。
