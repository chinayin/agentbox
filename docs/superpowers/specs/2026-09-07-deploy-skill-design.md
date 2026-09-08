# 发布技能设计

日期：2026-09-07。状态：待评审。

把 agentbox 实例投放到远程服务器的技能。本文只记设计与取舍，落地待办进 `ROADMAP.md`。

## 1. 要解决的问题

现在从"改完代码"到"服务器上跑着一个 agent"没有路径。`remote-build` 只负责在远端构建和 smoke，明确排除密钥、不部署实例；`new-instance` 只生成模板，交接清单上八步全靠人工在服务器上做。多一台机器、多一个 agent，这八步就重来一遍，且没有任何东西记录哪台机器上跑着什么。

目标是一条命令把某台主机上的实例发布到位，并让"哪台机器跑哪个版本的哪些 agent"成为可查的文件。

## 2. 已定决策

| # | 决策 | 理由 |
|---|---|---|
| 1 | 密钥从本地推送，本地是唯一真相 | 一条命令完成部署，改密钥即改本地文件，多实例可复制 |
| 2 | 部署配置放独立的私有 git 仓库 | 配置有变更历史和回滚，多机器可同步，agentbox 保持可开源 |
| 3 | `env` 明文提交进该仓库 | 克隆即可用，diff 能看到改了哪个值，不引入加密工具链 |
| 4 | 服务器从 GHCR 拉版本化镜像 | 实例 pin 版本，服务器上没有源码，回滚就是换 tag |
| 5 | 多台主机，每台若干实例 | 按主机分目录，一台主机一个 compose 工程 |
| 6 | 技能代码住 agentbox，部署仓库只放数据 | 脚本受 `make check` 保护，与 entrypoint 契约一起演进 |

决策 3 的后果单独说明：平台密钥与网关 token 的明文会进入 git 历史，且历史删不干净。仓库权限是唯一防线，一旦失控需要轮换全部凭据。这是明知代价后的选择，轮换流程写进 `docs/SECRETS.md`。

## 3. 两个仓库的边界

`examples/` 的性质收窄为纯模板：进 git，只有 `env.example`，由 `new-instance` 生成，供人复制。真实实例只活在部署仓库，那里才有填好值的 `config.toml` 和 `env`。

仓库根目录的 `docker-compose.yaml` 保持开发用途，镜像指向本地 `agentbox:dev`。生产 compose 在部署仓库里另写，镜像指向 GHCR。两份不共用，也不互相生成。

`new-instance` 的交接清单相应改写：第一步不再是"在 examples 下建 env"，而是"复制到部署仓库的哪台主机下"。

## 4. 部署仓库结构

仓库名建议 `agentbox-deploy`，GitHub 私有。

```
agentbox-deploy/
  README.md
  hosts/
    hk-test/
      host.env
      docker-compose.yaml
      instances/
        aliyun/{config.toml,env}
        demo/{config.toml,env}
    prod-cn/
      host.env
      docker-compose.yaml
      instances/...
```

`host.env` 是这台主机的连接方式和目标版本。字段分两类，上半段只在本地使用、绝不上传，下半段是 compose 变量、会派生到远端。连接字段沿用 `remote-build` 的形状，因为网络环境相同：

```
DEPLOY_HOST=root@xxx.xxx.xxx.xxx.sslip.io
DEPLOY_KEY=~/.ssh/xxxx.pem
DEPLOY_HOST_KEY_ALIAS=xxx.xxx.xxx.xxx
DEPLOY_SOCKS=127.0.0.1:7890
DEPLOY_DIR=/data/agentbox

# 以下派生到远端 .env
AGENTBOX_VERSION=1.2.3
```

`docker-compose.yaml` 里镜像引用变量，升级一台机器就是改 `AGENTBOX_VERSION` 一行，回滚同理：

```yaml
services:
  aliyun:
    image: ghcr.io/<owner>/agentbox:${AGENTBOX_VERSION}
    env_file: [./instances/aliyun/env]
    volumes:
      - ./instances/aliyun/config.toml:/agent/config.toml:ro
      - ./workspaces/aliyun:/workspace
      - aliyun-state:/state
      - aliyun-cache:/cache
```

技能自己的 `.claude/skills/deploy/.env` 只存一件事，即部署仓库在本地的路径，模板进 git、真值不进：

```
AGENTBOX_DEPLOY_REPO=~/path/to/agentbox-deploy
```

## 5. 服务器上的布局

服务器上只有部署产物，没有源码。

```
/data/agentbox/            DEPLOY_DIR
  docker-compose.yaml
  .env                     由 deploy 生成，只含 compose 变量，不含 ssh 连接信息
  instances/<name>/config.toml   0644
  instances/<name>/env           0600，属主 UID 1000
  workspaces/<name>/             由 deploy 在远端创建并 chown 到 UID 1000
```

state 与 cache 是 docker 命名卷，不在这棵树里，发布不触碰它们。这是有意的：state 卷承载 agent 的会话历史和工具写回的凭据，重新发布不该清空它。

## 6. 技能接口

```
deploy.sh plan   <host> [instance]
deploy.sh deploy <host> [instance]
deploy.sh status <host>
```

`plan` 做全部本地校验并打印影响面：将同步哪些文件、目标版本、将重启哪些容器。它完全不连接服务器，因此离线可用、快、且在任何时候执行都安全。

`deploy` 先跑一遍 `plan` 的校验，然后单向 rsync 到 `DEPLOY_DIR`，强制 `env` 为 0600，远端执行 `docker compose pull` 与 `docker compose up -d`，最后回读容器日志里的 precheck 输出并判断成败。省略 `instance` 表示整台主机。

`status` 打印远端 `docker compose ps` 和每个实例最近若干行日志。

日志按 `remote-build` 的既有做法 tee 回 `runtime/deploy/`，成功时把路径打到 stdout，失败时打到 stderr 并 exit 1。

## 7. 护栏

发布会重启正在服务的 agent，也会覆盖服务器上的密钥文件，所以护栏是这个设计的主体而不是附属。

1. **本地校验占位符。** 解析每个实例的 `config.toml`，确认它引用的每个 `${VAR}` 在同目录 `env` 里有值。这把 entrypoint 的 exit 2 提前到本地，省一次往返，缺值时不连服务器直接 exit 1。
2. **拒绝在脏仓库上发布。** 部署仓库有未提交改动时 exit 1，否则说不清服务器上跑的是哪个 commit。`--force` 可显式绕过，绕过时在日志里记下。
3. **权限强制。** `env` 落地即 `chmod 600`，属主对齐镜像的 AGENT_UID（默认 1000）。工作区目录同样对齐，因为 docker 会把缺失的绑定挂载目录建成 root。
4. **传输白名单且单向。** 只传 `hosts/<host>/` 下的 `docker-compose.yaml` 和 `instances/`。远端 `.env` 不来自同步，由 deploy 从 `host.env` 中提取 compose 变量后生成，ssh 地址与密钥路径留在本地。工作区目录由 deploy 在远端创建，不参与同步。绝不传 agentbox 源码，绝不从服务器往回同步。

## 8. 占位符解析的重复问题

`entrypoint.sh` 有一份占位符解析，`scripts/test.sh` 有第二份，`deploy.sh` 将是第三份。三份看起来在回答同一个问题，实际语义并不相同：`test.sh` 那份服务于 scaffold 模板校验，正则只认大写名字且有意丢掉 `WORK_DIR`，而 `entrypoint.sh` 那份允许小写与混合大小写。要求三者输出一致只会得到一条必须放水的断言。

真正需要锁住的是 `deploy.sh` 与 `entrypoint.sh` 这两处，因为前者决定本地放不放行、后者决定容器里报不报错，两者漂移就会出现本地过、容器崩的静默失配。`test.sh` 那份用途不同，不纳入。

不做代码提取，因为 entrypoint 在镜像里运行、本地脚本在宿主上运行，共享一个文件要动 Dockerfile 的 COPY 和运行期路径，代价高于收益。改为按仓库既有做法处理：`scripts/test.sh` 的 `contract consistency` 组新增一条断言，把同一个含大小写混合变量名的 config.toml 喂给这两处实现，要求名字集合完全相同。漂移会让 `make check` 变红。这条断言可行的前提是 `entrypoint.sh` 能在宿主上被 source，它那份解析只依赖 python3，而 `test.sh` 已经要求 python3 3.11 以上。

今天已发现并修复过一次同类问题：`test.sh` 那份曾把 `yield` 写进列表推导式，导致整段 Python 从不运行、断言恒真。这条契约断言正是为了让下一次漂移能被发现。

## 9. 测试

`scripts/test.sh` 新增 `deploy skill` 组，用临时目录里的假部署仓库做 fixture：

- `--help` exit 0
- 部署仓库路径的三级覆盖：技能 `.env` < 环境变量 < 命令行 flag
- 无任何路径来源时 exit 1
- `plan` 不建立网络连接
- 实例 `env` 少一个变量时被抓出并 exit 1
- 部署仓库有未提交改动时被拒，加 `--force` 后通过
- rsync 参数中不含 agentbox 源码路径
- 技能 `.env` 已被 `.gitignore` 覆盖
- 占位符解析三处一致（见第 8 节）

## 10. 前置条件

`v*` tag 发布链路从未跑过，GHCR 上目前没有任何 agentbox 镜像。技能写完也没有镜像可拉，所以顺序是：

1. 打一个 `v*` tag，确认 `release.yml` 先跑 ci 再推多架构镜像到 GHCR
2. 在目标服务器上 `docker login ghcr.io` 走通一次私有拉取，那个 PAT 是人工步骤，技能不代管
3. 再实现技能

第 1 步与第 2 步失败的话，方案要回退到在服务器上从源码构建，第 4、5、6 节全部重写。这是本设计最大的未验证假设。

## 11. 需要同步改动的文件

| 文件 | 改动 |
|---|---|
| `.claude/skills/new-instance/references/checklist.md` | 交接步骤改为面向部署仓库 |
| `.claude/skills/new-instance/SKILL.md` | 声明 `examples/` 是模板而非实例 |
| `docs/SECRETS.md` | 新增部署仓库这一层的密钥流向、明文入库的代价与轮换流程 |
| `docs/ROADMAP.md` | 新增前置条件与技能本身的验收项 |
| `scripts/test.sh` | 新增 `deploy skill` 组与占位符契约断言 |
| `README.md` | 挂载契约表不变，补一句发布路径的指引 |

`.gitignore` 的 `.claude/skills/*/.env` 已覆盖新技能，无需改动。

## 12. 非目标

- 不做密钥加密。决策 3 已排除。
- 不生成 compose。部署仓库里手写，`new-instance` 输出的片段贴过去即可。
- 不自动 `docker login`。GHCR 的 PAT 是人工步骤。
- 不做回滚自动化。改 `AGENTBOX_VERSION` 再发布就是回滚。
- 不做多环境 promote 流程。主机目录之间没有晋升关系。
- 不管宿主机引导。`ROADMAP.md` 已否决该范围。
