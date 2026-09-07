# 机器人 git 身份

任何自动化需要代码仓库权限，都先定身份类型，再按权限矩阵授权，并记录授权给了谁、多大权限。

## 1. 目标

独立身份（提交可辨识，不混在个人账号下）、可审计、按项目最小授权、一处禁用全部失效、新自动化按同一套流程办。

## 2. 身份方案

```
平台支持 Service Account（多为付费版）？ → 是：【A】Service Account（首选）
只需 1~2 个固定仓库，不要求提交身份可信？ → 是：【B】Project Access Token
其他（免费版 / 跨多仓库 / 要求身份可辨识）   →   【C】专用机器人用户账号
```

| 方案 | 优点 | 缺点 |
|---|---|---|
| A Service Account | 语义正确、无法交互登录、不占席位、可跨项目 | 通常需付费版，创建需管理员 |
| B Project Access Token | 创建最简单，作用域限定单项目 | 一仓一 token，有强制过期且到期静默失效，走 HTTPS 易泄进日志 |
| C 专用用户账号 | 免费版可用，独立 SSH 密钥与提交身份，完整活动审计 | 占一个席位，需约束"不当真人用" |

Deploy Key 不作主方案：它只回答"这把密钥能否推送"，不产生身份，提交作者由客户端 `git config` 决定，审计是假的；且一仓一挂。只读拉取且不在意身份时可用只读 deploy key。

## 3. 命名与记录

账号名带 `svc-` 前缀和用途（如 `svc-ai-agent`），显示名标明是机器人，简介写用途、宿主与负责人。每次授权记下账号、项目、角色、是否允许直推默认分支与日期，审计时才有对照物。

## 4. 权限矩阵

| 场景 | 角色 |
|---|---|
| 只拉代码 / 读 issue | Reporter（默认） |
| 提交、开 MR | Developer |
| 管理项目设置、改保护分支 | 不给。Maintainer / Owner 一律不授予自动化 |

硬性要求：默认分支开保护，机器人只推特性分支 + 开 MR；MR 由真人审批，机器人无 approve 权限；授权逐项目加，不加到顶层 group。

## 5. 可追溯性

agent 由聊天消息驱动，提交只记机器人身份就查不到人。做法：author 保持机器人，commit message 固定带 trailer。

```
fix(config): 调整某项限额

Triggered-by: 张三 <平台 open_id: ou_xxxxxxxx>
Session: <桥接器会话 id>
```

`git log --format='%(trailers:key=Triggered-by)'` 直接提取。不用 `git commit --author` 写成触发者：那会伪造真人身份，且掩盖"这是自动化产物"。

## 6. 容器内的密钥

私钥只在使用它的地方生成，不经过个人机器、不进仓库、不进对话。因为 `HOME=/state`，全部落在 state 卷，销毁卷即吊销本地一半。

```bash
ssh-keygen -t ed25519 -a 100 -f /state/.ssh/id_ed25519_git -C "svc-ai-agent@<实例名>" -N ""
chmod 600 /state/.ssh/id_ed25519_git
```

口令为空是无人值守的必然代价，由文件权限与容器隔离兜底。`/state/.ssh/config`（`0600`）：

```
Host git-upstream
    HostName <仓库主机>
    Port <端口>
    User git
    IdentityFile ~/.ssh/id_ed25519_git
    IdentitiesOnly yes
    StrictHostKeyChecking yes
```

`IdentitiesOnly yes` 防止多密钥时用错身份。首连不用 `StrictHostKeyChecking=no`，先 `ssh-keyscan` 核对指纹再写 `known_hosts`。

## 7. 可交给 agent 的操作提示词

四条共同设计：**先读后写、权限不足就停、不打印任何 token**。以 `glab` 为例，换平台改命令不改逻辑。

- **探测实例能力**：`glab api /version`、`/metadata`、`/license`（403 如实说明），据实际输出判断走方案 A 还是 C，不凭印象断言版本功能。
- **创建机器人账号（方案 C）**：先查 `/users?username=` 是否已存在；`POST /users` 创建，不授管理员、不加 group、不给项目权限；回读确认 user id；提示人工登录挂 SSH 公钥。
- **给项目授权**：取 project id；查现有成员避免重复；查 `protected_branches`，默认分支未保护则停下；按只读 Reporter / 提交 Developer 添加，绝不 Maintainer 以上；回读确认。
- **定期审计**：列出账号所有项目成员身份；对照授权记录找出记录外的项目；统计近 30 天推送 / MR 分布；标出高于 Developer 的角色、记录外项目、直推默认分支。只读，不处置。

## 8. 轮换与吊销

| 动作 | 做法 | 时机 |
|---|---|---|
| 轮换 | 生成新 ed25519 → 远端挂新公钥 → 验证 → 删旧公钥 | 每 12 个月，或人员变动 / 疑似泄漏 |
| 临时停用 | 远端 Block 账号 | 疑似异常，先停再查 |
| 彻底吊销 | 删账号 + 销毁 state 卷里的私钥 | 实例下线 |

吊销必须两边都做：只删本地私钥，远端公钥仍在；只 block 账号，本地私钥在账号恢复后重新生效。
