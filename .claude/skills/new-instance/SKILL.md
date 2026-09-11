---
name: new-instance
description: Add a new agentbox instance to this repository. Use this whenever the user wants another agent, bot, team instance, trust domain, or project added to the deployment, even when they only say things like "spin one up for the ops team", "add one more bot", or "put a second project into config.toml". It decides between adding a [[projects]] block to an existing instance and scaffolding a new instance, generates the instance's docker-compose.yaml, config template, env template and workspace directory, and hands back the manual checklist. It never asks for or writes real secret values.
---

# New instance

An agentbox instance is one directory and one compose project: its own `docker-compose.yaml`,
one `config.toml`, one env file, one workspace, one state volume, one cache volume. The repo's
rule is **one instance per trust domain, not per project** (`docs/MULTI_PROJECT.md` §1). So the
first thing to settle is whether the user needs a new instance at all.

**边界：** 已经有一台裸机在跑这个实例的，不要用本技能重造；用 `import-instance`（`.claude/skills/import-instance/SKILL.md`）从现状导入。本技能只服务「还没有」的实例。

## Step 1: pick the branch

Ask, if the request does not already say: *does the new work share the same secrets (chat app,
model gateway key) as an existing instance?*

- **Same secrets** → do not scaffold. Add a `[[projects]]` block, following the commented
  template at the bottom of `examples/demo/config.toml`. Which `config.toml` you edit depends on
  whether `<existing>` is already deployed: **not yet** → the template at
  `examples/<existing>/config.toml`. **Already live** → editing the template changes nothing
  running; edit the real `config.toml` in the deploy repo at
  `hosts/<host>/instances/<existing>/config.toml` instead, and push the change with the `deploy`
  skill. Table names carry no project name (`[projects.agent]`, never `[projects.<name>.agent]`);
  getting this wrong makes cc-connect start without an agent for the second project. New
  placeholders use a suffix (`FEISHU_APP_ID_<NAME>`); put the same suffixed names, with real
  values, in whichever env file sits next to the `config.toml` you edited — `env.example` (`xxxx`
  values) for a template, `env` in the deploy repo for a live instance. The workspace for the
  second project is a subdirectory of the existing one (`work_dir = "/workspace/<name>"`): create
  `runtime/workspaces/<existing>/<name>` by hand for a template instance; for a live one it lives
  on the server, and the `deploy` skill creates and owns it.
- **Same secrets, but a second container** (another agent CLI, its own workspace or limits, or
  isolation from a crash) → no scaffold either: add a second service to the existing instance's
  `docker-compose.yaml` with `<<: *agentbox`, its own `container_name`, config file and volumes,
  sharing `./env`. `docs/MULTI_PROJECT.md` §1 has the table.
- **Different secrets, repo, or team** → new instance. Continue with Step 2.

When in doubt, prefer the new instance: cross-domain calls are meant to have friction.

## Step 2: scaffold

```bash
.claude/skills/new-instance/scripts/scaffold.sh [--agent pi] [--mount kubeconfig] [--mount ssh_key] <name>
```

- `<name>` is lowercase letters, digits and dashes. It becomes the service name, the container
  name `agentbox-<name>`, the `examples/<name>/` directory and, once deployed, the compose project
  name (so the volumes are `<name>_state` / `<name>_cache` on the server).
- `--agent pi` sets `agent.type = "pi"`, uncomments `PI_KEY` in the env template and switches the
  image in `docker-compose.yaml` to the `-pi` tag. Default is `claudecode`.
- `--mount FILE` adds `./FILE:/agent/FILE:ro` to the instance's `docker-compose.yaml` (see
  `docs/TOOLS.md` §2 for which tool reads which path). `kubeconfig` also gets
  `KUBECONFIG=/agent/kubeconfig` written into the config's env block. Anything other than
  `kubeconfig` / `ssh_key` must be added to `.gitignore` under `examples/*/` before the real file
  is created.
- The script refuses to overwrite an existing `examples/<name>` (exit 1) and prints nothing on
  stdout; the three files are the product. Run with `--dry-run` first if you want to show the
  user the plan.

`examples/<name>/docker-compose.yaml` is cut from `examples/demo/docker-compose.yaml`: the shared
block (`x-agentbox`) is the deploy skill's policy and `deploy plan` refuses a file that drops any
of it, so edit only the service's own mounts. The root `docker-compose.yaml` is the local
development file and is not touched.

`examples/<name>/` stays a template: it goes in git with only `env.example`, never a filled-in
`env`. A real, running instance lives in the private deploy repository instead, and is published
there by the `deploy` skill, not by this one.

## Step 3: hand off

Read `references/checklist.md` and give the user the steps they must do themselves: copying the
template into the deploy repo, filling in values there, setting `allow_from` to explicit ids, and
verifying the model gateway. Workspace ownership, the `agentbox` network and starting the service
are the `deploy` skill's job now, not a manual step; point the user at it rather than describing
them as something to do by hand. Do not do the human steps for them, and do not put placeholders
for real values into the chat; the values go straight from the user into the `env` file in the
deploy repo.

## Guardrails

- Never write, request, echo or guess a real secret value. Templates hold `xxxx` shapes only;
  `scripts/test.sh` fails on anything else and `docs/SECRETS.md` explains why.
- Leave the README mount contract table, `entrypoint.sh` and the demo example alone. The demo is
  the template every scaffold copies from, `examples/demo/docker-compose.yaml` included: its
  shared block must stay in step with `deploy.sh`'s `check_compose`, and `scripts/test.sh` checks
  both.
- `allow_from = "*"` and `mode = "bypassPermissions"` together let anyone who can message the bot
  read every secret in the container. If the user wants either, say so once and keep the template's
  defaults unless they confirm.
- Finish with `make check`; the scaffolded files are part of the repo and must pass the same gate.

## Final message format

```
Created:
- examples/<name>/docker-compose.yaml   (image tag ..., mounts: ...)
- examples/<name>/config.toml           (agent.type = ...)
- examples/<name>/env.example
- runtime/workspaces/<name>/

Your steps: (from references/checklist.md, numbered)
```
