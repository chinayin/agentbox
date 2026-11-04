# mise 构建版本修复与发布计划

> For agentic workers: 使用 superpowers:executing-plans 在当前会话执行；步骤使用复选框记录。

**Goal:** 修复相同源码因 mise 自动升级而无法构建的问题，发布 v0.7.2 并升级北京既有三个实例。

**Architecture:** mise.toml 的 min_version 同时作为 lock 工作流和镜像 bootstrap 的精确版本来源。Dockerfile 从官方版本化发布资产安装 mise，校验该版本官方 SHA256；运行时仍按 mise*.lock 安装工具并保持离线。已有用户许可证改动和新增 cloudlog 不纳入此次发布。

**Tech Stack:** Docker BuildKit、mise、Bash、GitHub Actions、Docker Compose。

**Spec:** 本次会话用户确认的升级顺序；源码证据为 docs/TOOLCHAIN.md 与 .claude/skills/deploy/SKILL.md。

## Global Constraints

- mise 固定为已通过镜像 CI 的 2026.10.25，版本只声明在 mise.toml。
- 不关闭 locked mode，不关闭 SHA256 校验，不重新解析已合并的工具版本。
- 保留 linux/amd64 与 linux/arm64 构建能力；正式发布仍只构建 amd64。
- Git 提交和新增代码注释使用中文；不输出凭据、部署地址或完整生产日志。
- 北京现有 litellm-gateway、multicloud、uufly 逐个升级；不启动 cloudlog。
- 镜像发布成功、部署预检通过后才重建容器；保留 0.7.1 回滚路径和现有状态卷。

## Review Focus

- 官方 APT 索引只包含最新 mise，不得依赖历史 APT 版本可用。
- bootstrap 资产的架构映射必须正确；不支持的架构必须失败。
- SHA256 缺失或不匹配必须中止，不能安装未校验资产。
- 两个最终镜像必须运行声明的 mise 精确版本。
- 部署工作副本必须只包含既有实例，不能同步新增 cloudlog 或覆盖 workspace-init 的既有文件。

### Task 1: 固定 mise bootstrap 并验证

**Files:**
- Modify: Dockerfile、mise.toml、scripts/test.sh、scripts/smoke.sh、docs/TOOLCHAIN.md、docs/DECISIONS.md。

**Interfaces:**
- Consumes: mise.toml.min_version、Docker TARGETARCH、官方 SHASUMS256.txt。
- Produces: 两个最终镜像内固定版本的 /usr/local/bin/mise；已有工具锁文件不变。

- [x] 记录失败证据：main CI 41831130536 在 mise 2026.11.0 下因 AWS CLI、bats 缺少 checksum 失败；相同代码树在 mise 2026.10.25 下成功。
- [ ] 增加运行时 mise 精确版本检查；移除已失去前提的 extrepo 安装顺序断言。
- [ ] Dockerfile 从版本化发布包安装并校验 mise；min_version 更新为 2026.10.25。
- [ ] 更新工具链契约和决策记录。
- [ ] 运行 make check，预期全部通过；运行 CI 镜像构建和完整 smoke，预期两个作业通过。
- [ ] 独立审查修复，处理阻断问题后提交。

## 发布与部署

- 推送包含本地六个提交、远程锁文件更新和修复的代码；CI 通过后创建并推送 v0.7.2。
- 验证 release CI 与 GHCR 的 0.7.2、0.7.2-pi 镜像。
- 将北京部署版本改为 0.7.2，并把已经在线上生效的三个 env 改动记入本地部署仓库历史；cloudlog 保留未提交。
- 从该部署提交创建干净工作副本，展示脱敏 plan，按实例重建并验证健康、版本、挂载和技能安装。
- 任一实例失败则停止后续升级并恢复该实例原镜像版本；完成后同步当前源码工作区，恢复许可证改动。
