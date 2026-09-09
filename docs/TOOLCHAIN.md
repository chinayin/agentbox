# 工具链、版本策略与发布

镜像里的工具全部由 mise 声明、由 lock 锁定。`mise.toml` 写的是**更新策略**，`mise.lock` 才是构建真相：精确版本、双架构 URL，以及上游提供时的 SHA256。构建走 locked mode 只读 lock，当前平台缺 URL 直接失败；有校验和的条目安装时校验。

## 1. 组成

| 分组 | 工具 | backend |
|---|---|---|
| 运行时 | node、go、python | `core:` |
| Kubernetes 交付链 | kubectl、helm、helmfile、kustomize、helm-diff | `aqua:`，helm-diff 为 `github:` |
| 云厂商 CLI | aws-cli、aliyun-cli、cloudflared | `aqua:`，aliyun-cli 为 `github:` |
| 代码托管 CLI | gh、glab | `aqua:`，glab 为 `gitlab:` |
| 通用工具 | ripgrep、fd、jq、uv、bats、shellcheck、yamlfmt | `aqua:` |
| 桥接器 | cc-connect | `github:` |
| agent（每个一份覆盖层） | claude-code（`mise.claude.toml`）、pi（`mise.pi.toml`） | `aqua:` |

清单以 `mise.toml` 与各 `mise.<agent>.toml` 为准，本表只说明分组。公共工具链里不出现任何 agent CLI，`test.sh` 盯着这一点。backend 取舍：`core:` 与 `aqua:` 优先，aqua registry 带资产定义与上游校验和；不在 registry 的才用 `github:` / `gitlab:`，mise 按 OS/架构自动挑资产，挑错了再用 `asset_pattern` 点名；包内二进制带版本号的加 `rename_exe`（cc-connect）。短名（`glab`、`claude-code`）只是 registry 别名，配置里一律写完整 backend。

## 2. 版本策略

| 选择器 | 用于 | 理由 |
|---|---|---|
| `latest` | 所有独立 CLI | 版本由 lock 固定，toml 写精确号只是重复 |
| `prefix:1.37` | kubectl | 与集群 API server 只允许差一个小版本 |
| `prefix:4` | helm | 跨大版本破 chart |
| `26` / `prefix:1.26` / `3.14` | node / go / python | 跟大版本走 |

`test.sh` 断言 kubectl 与 helm 必须前缀限界、lock 里全是精确版本、toml 与 lock 工具集合一致。

两处预期内的"不对劲"：

- lock 版本可能比上游最新低一个 patch。mise 默认 `minimum_release_age = 24h`，发布不满一天的版本不算 latest。这是供应链保护，不要关。
- Claude Code 原生二进制默认后台自更新。镜像设 `DISABLE_UPDATES=1` 封住后台与手动更新，版本只由 lock 决定。

## 3. lock 生成

lock 由 mise 官方的 `mise lock` 生成，仓库只加了一层很薄的封装：

| 命令 | 实际执行 | 何时用 |
|---|---|---|
| `make lock` | `MISE_ENV=claude,pi mise lock --bump` | CI 的 `lock.yml` 每周或手动跑并开 PR |
| `make lock-refresh` | 同上但不 `--bump`，只刷新已锁版本的 URL/校验和 | 本机加一个工具 |

`MISE_ENV=claude,pi` 让 mise 同时加载 `mise.toml` 与每个 agent 覆盖层，一次写出 `mise.lock`、`mise.claude.lock`、`mise.pi.lock`，这是 mise 的环境 lock 机制；镜像里每个 agent 阶段只用自己的 `MISE_ENV=<agent>` 装那一层。平台列表、直连 GitHub 解析 latest（`use_versions_host = false`）、`minimum_release_age` 都是 `mise.toml` 里的官方设置，不靠命令行参数。GitHub token 由 mise 自己从 `GITHUB_TOKEN` 或 `gh` 登录态取。

lock 的生成与校验完全是 mise 官方机制，仓库不加自己的步骤。`mise lock` 只在上游提供校验和时记录：aqua 的 `http` 与 `github_archive` 类型资产（aws-cli、bats-core）上游没有校验和，lock 里只有版本化 URL，下载一致性靠 TLS 与固定文件名。这是已知取舍，不要手工往 lock 里补 checksum。

需要 mise ≥ `mise.toml` 的 `min_version`，mise 自己会检查。lock 以 CI（Linux）产出为准；mise 总会把当前平台也写进 lock，在 macOS 上跑会多出 `macos-arm64` 条目且之后一直保留，提交前删掉这些块，或加 `--platform linux-x64,linux-arm64` 只刷新 linux。brew 的 mise 通常版本不够：

```bash
curl -sS https://mise.run | MISE_VERSION=v2026.9.1 MISE_INSTALL_PATH=runtime/mise sh
MISE=runtime/mise make lock-refresh
```

lock 永远记上游 URL；构建机出网需要代理时用 docker 的 `HTTPS_PROXY` 构建参数，下载仍按同一份 lock 校验。见 [CN_MIRRORS](CN_MIRRORS.md)。

## 4. 加一个工具

1. 在 [mise-versions.jdx.dev](https://mise-versions.jdx.dev/) 查 backend 全名，或 `mise registry <短名>`。
2. 按 §1 的分组写进 `mise.toml`（agent CLI 进自己的 `mise.<agent>.toml`），选择器按 §2。不要同时用 apt 装同名包。
3. `MISE=... make lock-refresh && make test`。审 lock diff：只多出这一个工具，两个平台都有 `url`（上游提供时还有 `checksum`）。改过声明方式时旧块不会自动删，手工删掉。
4. `make check`，再用 remote-build 技能跑 `smoke`（`.claude/skills/remote-build/scripts/remote-build.sh smoke`）真实构建验证。smoke 按 lock 逐项核对安装，不需要为新工具改任何测试。

## 5. 构建与发布

| 阶段 | 位置 | 内容 |
|---|---|---|
| 门禁 | `ci.yml` check | `make check`（test / lint），每个 PR 与 main 推送 |
| 冒烟 | `ci.yml` smoke | `make image` + `make smoke`，amd64 |
| 发布 | `release.yml` publish | 只在 `vX.Y.Z` tag：先以 `workflow_call` 跑完 `ci.yml` 两段，再 buildx 双架构推 `ghcr.io/<repo>:X.Y.Z` 与 `-pi`；构建缓存走 `ghcr.io/<repo>-buildcache` 的 `:claude` 与 `:pi` 两个 ref |
| 升级 | `lock.yml` | 每周一或手动 `make lock`，有 diff 开 PR 并 dispatch `ci.yml` 跑该分支，审查后合并 |

版本唯一来源是 git tag：仓库里没有版本文件，也没有版本常量。发版就是在 main 上打 `vX.Y.Z`，CI 把 `X.Y.Z` 作为构建参数写进镜像的 `/etc/agentbox/version` 与 OCI label，`/entrypoint.sh --version` 读它。不打 `latest`，不用 git sha；main 推送不发布。重推同名 tag 会重跑 `release.yml` 并覆盖同名镜像，这是操作者的主动行为。本地 `make image` 固定产出 `dev` tag，`make image VERSION=x` 可以显式指定，但正式版只应由 CI 产出。CI runner 在境外，直连上游。默认 `GITHUB_TOKEN` 推的分支不触发 `pull_request` 事件，`lock.yml` 开完 PR 后用 `gh workflow run ci.yml --ref chore/mise-lock` 补跑（`workflow_dispatch` 不受这条递归限制），不需要 PAT。

构建缓存用 registry 后端而不是 `type=gha`：Actions 缓存的作用域是「写入它的那个 ref 加默认分支」，tag 触发的 run 写进去的缓存下一个 tag 永远读不到，而 `ci.yml` 也不给 main 写任何缓存可供回退——`v0.1.0` 因此白传了 1.59 GB。缓存放在独立的 `-buildcache` 包里而不是镜像的一个 tag 上，这样 `agentbox` 开为 public 后它的 tag 列表里只有真实版本，缓存包本身可以保持私有。两个变体共用**同一个** ref：它们只差一个工具、共享整条 toolchain，拆成两个 ref 会把这块体积存两份。

配额是这套方案的真实约束。GitHub Packages 只对 **private** 包计费，Pro 档是 2 GB 存储 / 10 GB 月流量，而这 2 GB 是账户下所有 private 包的总和。实测 `v0.1.0` 的缓存去重后 1.59 GB，`agentbox` 镜像包本身又是同一量级，两者相加大概率顶到 2 GB。超额后默认消费上限 $0 会拒绝写入，但 `cache-to` 的 `ignore-error=true` 会让它变成一条警告——**发布照常绿，缓存静默不生效**。看到发版时间没有下降就先查这里。Actions 内部触发的传输不计流量，所以流量不是约束。`agentbox` 开为 public 之后镜像包不再计费，缓存包留在 private 也装得下，这才是这套方案成立的前提。两个 `cache-to` 都带 `ignore-error=true`：镜像已经构建并推送成功之后，缓存导出失败不该让发布变红。`test.sh` 的 `workflow invariants` 组盯着这两条，外加并发组和 `workflow_call` 这两条。

手动构建：`make image [PLATFORM=linux/amd64] [BUILD_ARGS='--build-arg HTTPS_PROXY=...']`；本机网络不合适时用 remote-build 技能 `{probe,build,smoke}`（脚本在 `.claude/skills/remote-build/scripts/remote-build.sh`，构建机配置在同目录已忽略的 `.env`），日志落 `runtime/remote-build/`。

## 6. 镜像结构不变量

`test.sh` 有一组断言对应踩过的坑，改结构时同步维护；要删某条得先说清那个坑为什么不可能再复现（见 `CLAUDE.md`）：mise 双架构 lock、system scope 安装与 shims、运行期 `MISE_OFFLINE=true` 且禁止自动安装与系统回退、`MISE_IGNORED_CONFIG_PATHS` 覆盖挂载路径但不含 `/state`、`DISABLE_UPDATES=1`、helm 插件在 `/opt/helm/plugins`、未用 `go env -w`、Dockerfile 不显式点名 `mise install 工具@版本`。原因见 [ARCHITECTURE §5](ARCHITECTURE.md)。
