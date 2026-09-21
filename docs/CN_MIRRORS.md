# 境内使用

> 契约。镜像站可达性实测记录在 [DECISIONS](DECISIONS.md)，改任何地址前在实际网络复测并记日期。

镜像在哪构建和在哪运行是两个独立的问题，只有后者需要区分境内外。

## 1. 构建：永远直连上游

正式镜像只由境外 CI 从 git tag 构建，lock 记的是上游 URL 与校验和，构建地点不影响产物字节。仓库里没有构建期的境内镜像分支。

境内构建机出网困难时，用 docker 预定义的代理构建参数，apt、curl、mise 全部认这组变量，且不进入镜像层与历史：

```bash
make image BUILD_HTTPS_PROXY=http://proxy:port BUILD_HTTP_PROXY=http://proxy:port BUILD_NO_PROXY=localhost,127.0.0.1
```

代理只改传输路径，下载结果仍按 lock 里的 URL 与校验和验证；不能因为下载慢而关 lock。

## 2. 运行：`AGENTBOX_PROFILE=cn`

运行期境内源全部在仓库文件 `etc/agentbox/profiles/cn.env`，随镜像 COPY 进 `/etc/agentbox/profiles/`。`AGENTBOX_PROFILE=cn` 时 entrypoint 逐行导出，只填未显式设置的变量；global 没有文件，工具用官方默认值。smoke 会核对文件里每个键都真的出现在容器环境里。

| 生态 | 变量 | 说明 |
|---|---|---|
| Go | `GOPROXY`、`GOSUMDB` | goproxy.cn 在前，阿里云 goproxy 作后备 |
| npm | `npm_config_registry`、`npm_config_disturl` | disturl 给 node-gyp 编译原生模块时下载 headers |
| pip / uv | `PIP_INDEX_URL`、`UV_DEFAULT_INDEX` | 两个工具不互认变量，各设一个 |
| Hugging Face | `HF_ENDPOINT` | huggingface_hub / transformers / datasets |

这些只改"从哪下载"，不改工具版本；镜像工具链本身在运行期是离线锁死的（`MISE_OFFLINE`）。

怎么开：这是主机的属性，不是实例的。本地开发在仓库根目录的 `.env` 里写 `AGENTBOX_PROFILE=cn`，compose 透传；正式部署写在部署仓库 `hosts/<host>/host.env`，`deploy` 技能把它和版本一起派生进服务器上每个实例目录的 `.env`，实例 compose 的共享块用 `environment: {AGENTBOX_PROFILE: "${AGENTBOX_PROFILE:-global}", TZ: "${TZ:-UTC}"}` 接进容器（`TZ` 是同一通道里的另一项主机事实，容器时钟与 cron 调度按它走），`plan` 会拒绝少了这行的 compose。实例自己的 `env` 文件不放这个变量。值只认 `cn` 与 `global`，别的在 `plan` 就报错：entrypoint 对未知 profile 只在容器日志里警告一句，然后按上游源跑，必须在部署前拦住（[DECISIONS](DECISIONS.md) 2026-09-21）。

刻意没加的：Electron、Playwright、Puppeteer 的二进制镜像。镜像里没有浏览器运行时依赖，这些包在 agentbox 里本来就跑不起来；真要用时在实例 `config.toml` 的 env 块里自己加。
