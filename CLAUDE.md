# agentbox

挂载驱动的 AI agent 运行时镜像。设计与约束以 `README.md` 和 `docs/` 为唯一真相，本文件只写在这个仓库里干活的规则。规则跟着代码走：某条不再符合现状就改它，不要为了守规则留死代码或绕远路。

- 改动前先读 `docs/ARCHITECTURE.md` §1 的三条原则和 §5 的构建期陷阱。要违反任何一条，先停下来讨论，不要直接改。
- 改 Dockerfile 或 mise 配置前读 `docs/TOOLCHAIN.md`。版本只来自 lock，不在 Dockerfile 写死任何工具版本。
- 语言：文档类（`README.md`、`docs/`、根目录其他 `*.md`）中文；代码类（脚本、Dockerfile、Makefile、compose、workflow、toml、env 模板）的注释、帮助、报错、日志、测试用例名一律英文——包括状态输出的 `Error:`/`Warning:` 前缀，大小写照写。这条对齐 `gox-code-rules:shell`（0.6.1 起明确要求消息用英文：这些串会被工具 grep、diff、贴进 issue，本地化字符串匹配不到，纯 ASCII 也天然绕开下面那个 brace 陷阱）。2026-09-07 曾按旧版标准把 `deploy.sh` 的前缀写成中文，2026-09-09 随标准更新改回英文；别再翻回去。两处仍是例外：`scripts/test.sh` 里用来匹配中文文档的 grep 模式，以及 `shell standards` 组里拼 `${q}` 用的中文前缀样本——翻了它们就永远匹配不到、永远 PASS，已就地注明。
- 两个 gox 标准都写了「代码注释用中文」，本仓库有意不跟：仓库面向开源，注释与 `README.md`/`docs/` 的中文是刻意分工；另外全英文注释让每个脚本保持纯 ASCII，brace 陷阱无从触发。改这条前先讨论。
- 挂载契约有两份（`README.md` 的表 和 `entrypoint.sh --help`），entrypoint 的错误文案还被 `scripts/smoke.sh` 引用。这些重复由 `test.sh` 的 `contract consistency` 组盯着。改单边会红，不要绕过它。
- 提交前跑 `make check`。`scripts/test.sh` 的断言对应踩过的坑：可以删，但要能说清那个坑为什么不可能再复现；改结构时同步维护。永远 PASS 的断言比没有断言更糟。
- `make check` 不含 `make smoke`（后者要 docker）。改 entrypoint 的输出后，要么跑 `make smoke`，要么确认 `contract consistency` 已覆盖。
- 改 `.github/workflows/` 要同步 `docs/TOOLCHAIN.md` §5 的表格和 `docs/ROADMAP.md` 里的 CI 验收项，test.sh 不查这两处。workflow 本身只被 `workflow invariants` 组盯住并发组和 `workflow_call` 这三条不变量（2026-09-08 的 tag 死锁），其余仍靠人工。
- 待办只写 `docs/ROADMAP.md`。未经真实环境验证的事项不得在文档里写成已确认。
- 明文密钥不进 git、文档、对话、报告。模板只放 `xxxx` 占位值，见 `docs/SECRETS.md`。
