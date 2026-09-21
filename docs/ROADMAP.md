# 未完成事项

> 记录。每项只写现状与验收，做完直接删行。历史与已否决项在 [DECISIONS](DECISIONS.md)。未经真实环境验证的事项不得在契约文件里写成已确认。

## P1 需要真实环境收口

| # | 事项 | 现状 | 验收 |
|---|---|---|---|
| 1 | `linux/arm64` 镜像在 arm64 上跑通 | 发布关闭（原因见 DECISIONS 2026-09-09）。`v0.3.0` 含 arm64 层但从未运行过 | Apple Silicon 上 `docker run ghcr.io/<repo>:0.3.0 --version` 成功；重开发布需先有真实 arm64 部署目标 |
| 2 | `relay send --data-dir` 跨容器 | 源码判定不可行（DECISIONS 2026-09-13），未实测 | 两容器实验确认 `target engine not found` 后，把 `INSTANCES.md` §3 的「未实测」去掉 |
| 2a | 多云 relay 拓扑（一容器多 project）真机验证 | multicloud 已按「一 bot + 四 subagent」形态上线（DECISIONS 2026-09-21），不走 relay；`docs/design/MULTI_CLOUD.md` §3 的 relay 语义仍全部基于源码判定 | 只在有人需要单独 @ 某家云的 bot 时再做：同容器两个 project，主 bot 对跨两家云的问题至少 relay 一次并汇总回人 |
| 2b | 飞书 `include_bot` 权限与 cc-connect 放行 bot @ 消息 | `docs/design/MULTI_CLOUD.md` §4，租户能否申请该范围未确认，cc-connect 接收路径未真机跑过 | 两个测试应用互 @ 一次双方会话都收到；`mention_map` 出站 @ 能触发对方事件 |
| 2c | `cc-connect feishu new` 扫码建飞书应用 | 只有上游文档与源码（`PersonalAgent` 模板），本仓库的应用都在后台手建 | 用镜像内的 cc-connect 扫码建一个测试应用，后台导出的权限 JSON 与 `docs/CHANNELS.md` §2.2 一致，事件与回调已订阅并为长连接 |
| 2d | 多账号名册渲染脚本 | `docs/design/CLOUD_ACCOUNTS.md` §2 定了 `accounts.yaml` 为唯一真相与四样产物，脚本未写 | 一份含 aws/aliyun/volc 各一个别名的 YAML 渲染出四样产物；`test.sh` 断言产物里没有 `[default]`、白名单与 YAML 别名一致 |
| 2e | 多账号强制层真机验证 | 部署期校验已做（`verify-profiles.sh`，2026-09-13 六个 profile 全 PASS）。提示层、托管钩子、沙箱变量屏蔽、`-admin` 别名的飞书确认都只到文档层 | AWS 专才挂两个别名：不带 `--profile` 的命令被钩子拒绝；`AWS_PROFILE=x aws ...` 被拒绝；只读别名的 `get-caller-identity` 回显正确账号；`-admin` 别名的写命令在飞书弹出确认 |
| 3 | 真人开的 PR 上 `pull_request` 事件的 ci 跑绿 | `lock.yml` 链路已闭环（DECISIONS 2026-09-14）。bot 开的 PR 那次 `pull_request` 运行是 GitHub 的递归保护，预期内失败。真人开的 PR 还没有过 | 真人开一个 PR，`pull_request` 触发的两段自然绿，不靠 dispatch |

## P2 加固

| # | 事项 | 现状 | 验收 |
|---|---|---|---|
| 6 | compose 加固：`read_only: true` + tmpfs + healthcheck | pids、cap_drop、no-new-privileges、init 已在真实实例上 `docker inspect` 验收（DECISIONS 2026-09-21）。`read_only` 与 healthcheck 未做；`make smoke` 走裸 `docker run` 不经过 compose。cc-connect 凭据无效时不退出只刷 websocket error，healthcheck 不能只看进程 | 实例 `healthy` 且日志无 `read-only file system` |
| 7 | pi 会话端到端 | `agent.type = "pi"` 已被 cc-connect 接受并启动引擎，未用真实凭据驱动过会话；entrypoint 按清单把技能装进 `/state/.pi/agent/skills`，pi 是否从这个目录加载未验 | 真实飞书应用 + `-pi` 镜像，发一条消息拿到回复；同一实例挂 `skills-lock.json`，pi 会话里能用上其中的技能 |
| 8 | state 卷备份/恢复脚本 | 无脚本；卷内含 git 私钥 | `scripts/state-backup.sh`，文档标注备份件密级 |
