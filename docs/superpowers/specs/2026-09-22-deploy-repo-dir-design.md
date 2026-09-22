# 部署仓库落到 `deploy-repo/`，`new-instance` 直接写实例

日期：2026-09-22。状态：待评审。

## 1. 要解决的问题

第一次使用的人从「clone 了 agentbox」到「服务器上跑起第一个实例」没有连贯路径：

- `new-instance` 把产物写进 agentbox 仓库的 `examples/<name>/`，然后要人手工复制到部署仓库、把 `env.example` 改名 `env`。`examples/` 是随仓库发布的模板与样例，不是实例该住的地方。
- 部署仓库的位置靠 `.claude/skills/deploy/.env` 里的 `AGENTBOX_DEPLOY_REPO`，`import-instance` 再去读 `deploy` 技能的 `.env`。三个技能、一个路径、两层间接。
- 部署仓库的骨架（`defaults.env`、`hosts/<host>/host.env`）只在 `deploy-repo.md` 里有描述，没有任何东西生成它。

## 2. 已定决策

| # | 决策 | 理由 |
|---|---|---|
| 1 | 部署仓库的约定位置是 agentbox 根目录下的 `deploy-repo/`，gitignored | 一个 clone 里有全部东西；三个技能不再各读一份 `.env`。名字直说它是另一个仓库，与 `references/deploy-repo.md` 同名；不用点前缀，这是每天要进去改的目录 |
| 2 | `deploy-repo/` 可以是真 clone，也可以是指向别处的软链 | git 对 gitignored 目录里的嵌套仓库和软链都不管；已有布局的人一条 `ln -s` 迁过来 |
| 3 | 路径解析统一为 `--repo` > `AGENTBOX_DEPLOY_REPO` > `<root>/deploy-repo`（存在时） | 非常规布局与 CI 仍有口子；`.claude/skills/deploy/.env` 及其 `.env.example` 删除，`import-instance` 不再读 `deploy` 的 `.env` |
| 4 | `new-instance` 的产物是 `deploy-repo/hosts/<host>/instances/<name>/{docker-compose.yaml,config.toml,env}`，`env` 0600、只含 `xxxx` 占位 | 实例只活在部署仓库；少一次复制改名。`examples/` 只剩模板（demo）与样例（multicloud） |
| 5 | `--host` 可省，默认 `default` | 单机用户不用先学 host 概念 |
| 6 | `hosts/<host>/host.env` 与 `defaults.env` 缺失时由 scaffold 从模板生成，全占位值，stderr 列出要填的文件 | 第一次使用不必手抄 `deploy-repo.md`；`deploy plan` 会因占位值未填而拒绝，不会带着 `xxxx` 上线 |
| 7 | scaffold 不再创建工作区目录 | 工作区在服务器上，`deploy` 建并 chown；本机 `runtime/workspaces/` 只服务根目录的本地开发 compose |
| 8 | `deploy-repo/` 不放进 `runtime/` | `runtime/` 是可随手删的产物；部署仓库是有远端的真仓库 |

## 3. 目录与解析

```
agentbox/
  deploy-repo/            # gitignored；真 clone 或软链
    defaults.env
    hosts/<host>/host.env
    hosts/<host>/instances/<name>/{docker-compose.yaml,config.toml,env,home/,...}
```

`deploy.sh`、`import-instance.sh`、`scaffold.sh` 三处同一段解析：`--repo` 给了用它；否则 `AGENTBOX_DEPLOY_REPO`；否则 `<root>/deploy-repo` 存在就用。三者皆无时退出 2，报错指向 `deploy-repo.md`：clone 或软链部署仓库到 `<root>/deploy-repo`，或传 `--repo`。`<root>` 由脚本位置推出，测试用 `--root` 覆盖。

## 4. `scaffold.sh` 的新行为

```
scaffold.sh [--host H] [--agent pi] [--repo DIR] [--dry-run] <name>
```

1. 解析部署仓库；`hosts/<host>/instances/<name>/` 已存在则退出 1。
2. `defaults.env` 缺失则从模板生成（`AGENTBOX_VERSION=x.x.x`）。`host.env` 缺失则从模板生成（`deploy-repo.md` 里那份，`xxxx` 值）。两份模板放 `.claude/skills/deploy/references/`，`deploy-repo.md` 只链接不再内嵌。
3. 从 `examples/demo` 生成 `docker-compose.yaml`、`config.toml`、`env`（0600），改写逻辑与现在相同。
4. stderr 列出创建的文件，并单独列出「需要填值」的文件：新生成的 `host.env`、`defaults.env`、`env`。stdout 无输出。

部署仓库不是 git 仓库时告警不阻断，与 `deploy.sh` 一致。

## 5. 第一次使用的路径

```bash
git clone <agentbox>; cd agentbox
git clone <私有部署仓库> deploy-repo      # 或 git init deploy-repo
.claude/skills/new-instance/scripts/scaffold.sh <name>
# 填 deploy-repo/hosts/default/host.env、defaults.env、instances/<name>/env；提交
.claude/skills/deploy/scripts/deploy.sh plan default <name>
.claude/skills/deploy/scripts/deploy.sh deploy default <name>
```

写进 README「快速开始」，与现有本地开发那段并列。

## 6. 改动清单

| 文件 | 改动 |
|---|---|
| `.gitignore` | 加 `/deploy-repo`；删 `.claude/skills/*/.env` 中 deploy 那份的用途说明（规则本身留给 `import-instance` / `remote-build`） |
| `.claude/skills/deploy/scripts/deploy.sh` | 删 `.env` 加载；解析加默认目录；报错文案 |
| `.claude/skills/deploy/.env.example` | 删除 |
| `.claude/skills/deploy/SKILL.md`、`references/deploy-repo.md` | Configuration 段改为约定目录；`host.env` / `defaults.env` 内容挪成模板文件 |
| `.claude/skills/deploy/references/host.env.example`、`defaults.env.example` | 新增 |
| `.claude/skills/import-instance/scripts/import-instance.sh`、`SKILL.md` | 不读 `deploy` 的 `.env`；解析同上 |
| `.claude/skills/new-instance/scripts/scaffold.sh`、`SKILL.md`、`references/checklist.md` | §4；checklist 删「复制到部署仓库」一步；Final message 改路径 |
| `scripts/test.sh` | scaffold 组改为对临时部署仓库断言（`env` 0600、`host.env` 与 `defaults.env` 生成且全占位、不再建工作区）；deploy 组删 `.env` 断言，加默认目录解析与缺失时 exit 2 |
| `README.md` | 快速开始加服务器路径；开发段技能一句改写 |
| `docs/INSTANCES.md` §1 末段 | `new-instance` 写部署仓库 |
| `docs/DECISIONS.md` | 一条：部署仓库约定位置与命名 |

## 7. 风险

- `git clean -fdx` 会删掉 `deploy-repo/`。部署仓库有远端，`deploy plan` 已拒绝脏仓库，所以最多丢未提交改动。写进 `deploy-repo.md`。
- 现有用户的 `.claude/skills/deploy/.env` 失效。迁移是 `ln -s <原路径> deploy-repo`，写进 DECISIONS 那条。
