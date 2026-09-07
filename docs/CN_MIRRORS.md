# 境内使用

镜像在哪构建和在哪运行是两个独立的问题，只有后者需要区分境内外。

## 1. 构建：永远直连上游

正式镜像只由境外 CI 从 git tag 构建，lock 记的是上游 URL 与校验和，构建地点不影响产物字节。仓库里没有构建期的境内镜像分支。

境内构建机出网困难时，用 docker 预定义的代理构建参数，apt、curl、mise 全部认这组变量，且不进入镜像层与历史：

```bash
make image BUILD_ARGS='--build-arg HTTPS_PROXY=http://proxy:port --build-arg HTTP_PROXY=http://proxy:port --build-arg NO_PROXY=localhost,127.0.0.1'
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

刻意没加的：Electron、Playwright、Puppeteer 的二进制镜像。镜像里没有浏览器运行时依赖，这些包在 agentbox 里本来就跑不起来；真要用时在实例 `config.toml` 的 env 块里自己加。

## 3. 实测记录

| 日期 | 环境 | 结论 |
|---|---|---|
| 2026-09-05 | 阿里云香港 x86_64 | 直连上游完整构建 + smoke 通过 |
| 2026-09-06 | 开发机 | 运行期 cn.env 各地址可达性探测均 200：mirrors.aliyun.com/pypi、registry.npmmirror.com、npmmirror.com/mirrors/node（含 headers 包）、hf-mirror.com、goproxy.cn；阿里云 goproxy 响应约 8 秒，故放后备位 |

镜像站可用性有时效，改任何地址前在实际网络复测并记日期。
