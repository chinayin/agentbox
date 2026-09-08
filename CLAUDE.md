# agentbox

挂载驱动的 AI agent 运行时镜像。设计与约束以 `README.md` 和 `docs/` 为唯一真相，本文件只写在这个仓库里干活的规则。规则跟着代码走：某条不再符合现状就改它，不要为了守规则留死代码或绕远路。

- 改动前先读 `docs/ARCHITECTURE.md` §1 的三条原则和 §5 的构建期陷阱。要违反任何一条，先停下来讨论，不要直接改。
- 改 Dockerfile 或 mise 配置前读 `docs/TOOLCHAIN.md`。版本只来自 lock，不在 Dockerfile 写死任何工具版本。
- 语言：文档类（`README.md`、`docs/`、根目录其他 `*.md`）中文；代码类（脚本、Dockerfile、Makefile、compose、workflow、toml、env 模板）的注释、帮助、报错、日志、测试用例名默认英文。测试脚本里用来匹配中文文档的 grep 模式是例外之一，已就地注明，别顺手翻译——翻了它就永远匹配不到、永远 PASS。另一处例外：2026-09-07 起用户明确指示团队 `gox-code-rules:shell` 标准优先于本条，`.claude/skills/deploy/scripts/deploy.sh` 按该标准把状态输出的 `错误:`/`警告:` 前缀写成中文——脚本其余的注释、帮助文本（`--help`）和日志消息正文仍是英文，跟仓库其它脚本一致，换语言的只有这两个前缀词。`entrypoint.sh`、`scripts/*.sh` 与更早的技能不受影响，继续保持英文；`scripts/test.sh` 里的断言名同样保持英文，避免同一份 `[PASS]` 输出中英混杂。见到 `deploy.sh` 里的英文报错文案或别处的中文前缀，不要顺手"统一"成任何一边——这就是这条例外要描述的稳定状态。
- 挂载契约有两份（`README.md` 的表 和 `entrypoint.sh --help`），entrypoint 的错误文案还被 `scripts/smoke.sh` 引用。这些重复由 `test.sh` 的 `contract consistency` 组盯着。改单边会红，不要绕过它。
- 提交前跑 `make check`。`scripts/test.sh` 的断言对应踩过的坑：可以删，但要能说清那个坑为什么不可能再复现；改结构时同步维护。永远 PASS 的断言比没有断言更糟。
- `make check` 不含 `make smoke`（后者要 docker）。改 entrypoint 的输出后，要么跑 `make smoke`，要么确认 `contract consistency` 已覆盖。
- 改 `.github/workflows/` 要同步 `docs/TOOLCHAIN.md` §5 的表格和 `docs/ROADMAP.md` 里的 CI 验收项，test.sh 不查这三处。
- 待办只写 `docs/ROADMAP.md`。未经真实环境验证的事项不得在文档里写成已确认。
- 明文密钥不进 git、文档、对话、报告。模板只放 `xxxx` 占位值，见 `docs/SECRETS.md`。
