# agentbox

挂载驱动的 AI agent 运行时镜像。设计以 `README.md` 和 `docs/` 为唯一真相，本文件只写在这个仓库里干活的规则。规则跟着代码走：某条不再符合现状就改它，不要为了守规则留死代码或绕远路。

## 改动前

- 读 `docs/ARCHITECTURE.md` §1 的三条原则和 §5 的陷阱。要违反任何一条，先停下来讨论。
- 改 Dockerfile 或 mise 配置前读 `docs/TOOLCHAIN.md`。版本只来自 lock，Dockerfile 不写死任何工具版本。
- 凭据相关（变量、文件、挂载）只按 `docs/CREDENTIALS.md` 的三条通道做，文件型凭据一律走实例目录 `home/`，不再单文件挂 `/agent/<文件>`。

## 文档

`docs/` 分三类，每份开头一行标明，`README.md` 的文档表是索引：

- **契约**（ARCHITECTURE、TOOLCHAIN、CREDENTIALS、INSTANCES、SKILLS、GIT_IDENTITY、CN_MIRRORS）：只写现状，用「必须 / 不得」，不写日期、不讲历史、不写「建议考虑」。一个事实只写在一处，别处链接过去。
- **记录**（ROADMAP、DECISIONS）：ROADMAP 每项带验收条件，做完删行；DECISIONS 只增不改，为什么这样选、否决了什么、实测数字都在这里。
- **设计稿**（`docs/design/`）：未实现的方案，首行标「未实现」。契约文件不得把设计稿的内容当现状引用；实现一段就把契约部分挪进正文。

文档里关于行为的断言，要么 `scripts/test.sh` 盯着，要么删掉。未经真实环境验证的事项只能出现在 ROADMAP 或设计稿里。

## 语言

- 文档类（`README.md`、`docs/`、根目录其他 `*.md`）中文。
- 代码类（脚本、Dockerfile、Makefile、compose、workflow、toml、env 模板）的注释、帮助、报错、日志、测试用例名一律英文，包括 `Error:` / `Warning:` 前缀。这些串会被工具 grep、diff、贴进 issue，且纯 ASCII 天然绕开 shell 的 brace 陷阱。两处例外已就地注明：`scripts/test.sh` 里匹配中文文档的 grep 模式，以及 `shell standards` 组里拼 `${q}` 用的中文前缀样本。
- 两个 gox 标准都写「代码注释用中文」，本仓库有意不跟：仓库面向开源，注释与中文文档是刻意分工。改这条前先讨论。

## 提交前

- 跑 `make check`。`scripts/test.sh` 的每条断言对应踩过的坑：可以删，但要能说清那个坑为什么不可能再复现；改结构时同步维护。永远 PASS 的断言比没有断言更糟。
- `make check` 不含 `make smoke`（要 docker）。改 entrypoint 的输出后，要么跑 `make smoke`，要么确认 `contract consistency` 组已覆盖。
- 挂载契约有两份（`README.md` 的表和 `entrypoint.sh --help`），entrypoint 的错误文案还被 `scripts/smoke.sh` 引用，由 `contract consistency` 组盯着。改单边会红，不要绕过它。
- 构建定义只有 `docker-bake.hcl` 一份，`make image`、`ci.yml`、`release.yml` 都调它。加 target、平台或 build arg 只改它。调 bake 必须带 `-f docker-bake.hcl`，代理变量必须带 `BUILD_` 前缀，由 `workflow invariants` 组看着。
- 改 `.github/workflows/` 要同步 `docs/TOOLCHAIN.md` §5 的表格，test.sh 不查这处。

## 红线

明文密钥不进 git、文档、对话、报告。模板只放 `xxxx` 占位值，见 `docs/CREDENTIALS.md` §5。
