---
name: import-instance
description: Import a cc-connect instance that runs directly on a server (npm-installed cc-connect under systemd, config.toml and .env in a directory) into this repository's deploy shape. Use it whenever the user wants to migrate, move, containerize or "搬迁 / 迁移 / 导入" an existing agent from a physical or virtual machine into agentbox, or asks what a bare-metal instance would look like as mounts. It reads the source host read-only, writes hosts/<host>/instances/<name>/ in the deploy repo with the real values and the instance's own docker-compose.yaml, and prints the migration plan. It never deploys; that is the deploy skill's job.
---

# Import instance

`new-instance` 从模板造空壳，本技能从现状反推：读一台已经在跑的裸机实例，按挂载契约（`README.md` 的表）把它改写成部署仓库里的一个实例目录。源主机全程只读，源实例不停。

## 配置

源主机连接信息在 `.claude/skills/import-instance/.env`（gitignored，模板 `.env.example`），形状与 `remote-build` 相同；Clash 之类规则代理下用 `<ip>.sslip.io` 加 host-key alias。部署仓库路径复用 `deploy` 技能的 `.env`（`AGENTBOX_DEPLOY_REPO`），不另配。两个 `.env` 缺任何一个，都指向对应的 `.env.example` 然后停下，不在 chat 里问地址或路径。

## 动作

```bash
.claude/skills/import-instance/scripts/import-instance.sh plan   <source-dir>
.claude/skills/import-instance/scripts/import-instance.sh import <source-dir> --host <host> --name <name>
```

- `<source-dir>` 是源主机上含 `config.toml` 与 `.env` 的目录（systemd 单元里的 `WorkingDirectory` 或 `EnvironmentFile` 所在目录）。
- 先跑 `plan`，把规划表给用户看，尤其是末尾的「red items」。它只读、不写文件。
- `import` 要求 `hosts/<host>/host.env` 已存在（见 `.claude/skills/deploy/references/deploy-repo.md`）。目标目录已存在时 exit 1，不覆盖。
- `--local`（源目录仍是位置参数，配合 `--home` 指向源侧家目录的副本）；用于离线检查。
- `--dry-run` 打出将执行的 ssh 与将写的路径，不连接、不写。

## 读结果

规划表六段：`artifacts`（每个源产物去哪、靠哪条通道）、`config rewrites`（哪些字面值变成了占位符）、`file credentials`、`skills`、`tools`（源侧 CLI 对 `mise.lock`）、`red items`。红项是需要人判断的：`bypassPermissions`、技能运行路径依赖 docker、工具不在 lock、源 config 里写死了密钥、占位符没有值。映射规则的完整版在 `references/mapping.md`。

`import` 的 stdout 只有规划表；stderr 最后一行给出下一步命令。实例的 `docker-compose.yaml` 直接写进目标目录（从 `examples/demo/docker-compose.yaml` 改名而来，每个凭据文件与技能清单各一条 `./<file>:/agent/<file>:ro` 挂载），不再有需要手贴的片段。真值只在 `instances/<name>/` 下的文件里，规划表与 compose 文件里没有任何值。

## 交接给用户的步骤

1. 检查 `env`：聊天应用若要换（同一个飞书应用不能有两个 cc-connect 消费者），改 `FEISHU_APP_ID` / `FEISHU_APP_SECRET`，并把 `config.toml` 里的 `allow_from` / `admin_from` 换成新应用下的 open_id。
2. 代理三件（`HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`）按目标主机的出网路径决定留或清空；模型网关地址要能从目标主机访问。
3. 多份 kubeconfig 只保留目标主机该有的那几份，删掉的同时从 `config.toml` 的 `KUBECONFIG` 与 `docker-compose.yaml` 的 volumes 里去掉对应项。
4. 提交部署仓库。`docker-compose.yaml` 的共享块（`x-agentbox`）是 `deploy` 的策略，`deploy plan` 会逐文件校验，只改 service 自己的挂载。
5. 工作区：`deploy` 会建 `workspaces/<name>/` 并 chown；仓库 clone 是在主机上手工做的，属主 UID 1000。
6. 然后走 `deploy` 技能：`plan <host> <name>` 看输出，再 `deploy`，再 `status`。

## 护栏

- 源主机只读：`collect.sh` 没有任何写操作，`scripts/test.sh` 盯着。
- 真值只落 `instances/<name>/`，且 0600；不进 stdout、stderr、日志、chat。规划表里出现值就是 bug。
- 只写 `instances/<name>/` 一个目录（含它自己的 `docker-compose.yaml`），不碰部署仓库其他文件与 agentbox 源码目录，不迁会话历史与 `~/.claude.json`。
- 不停、不改源实例；切换由用户在验证新实例之后自己做。
- 完成后跑 `make check`。
