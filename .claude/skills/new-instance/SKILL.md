---
name: new-instance
description: Add a new agentbox instance to this repository. Use this whenever the user wants another agent, bot, team instance, trust domain, or project added to the deployment, even when they only say things like "spin one up for the ops team", "add one more bot", or "put a second project into config.toml". It decides between adding a [[projects]] block to an existing instance and scaffolding a new instance, writes the instance's docker-compose.yaml, config.toml and env (placeholders only) into the deploy repo under deploy-repo/, laying out host.env and defaults.env when they are missing, and hands back the manual checklist. It never asks for or writes real secret values.
---

# New instance

An agentbox instance is one directory and one compose project: its own `docker-compose.yaml`,
one `config.toml`, one env file, one workspace, one state volume, one cache volume. The repo's
rule is **one instance per trust domain, not per project** (`docs/INSTANCES.md` §1). So the
first thing to settle is whether the user needs a new instance at all.

**边界：** 已经有一台裸机在跑这个实例的，不要用本技能重造；用 `import-instance`（`.claude/skills/import-instance/SKILL.md`）从现状导入。本技能只服务「还没有」的实例。

## Step 1: pick the branch

Ask, if the request does not already say: *does the new work share the same secrets (chat app,
model gateway key) as an existing instance?*

- **Same secrets** → do not scaffold. Add a `[[projects]]` block, following the commented
  template at the bottom of `examples/demo/config.toml`, to the instance's real `config.toml` in
  the deploy repo, `deploy-repo/hosts/<host>/instances/<existing>/config.toml`, and push the change
  with the `deploy` skill. Table names carry no project name (`[projects.agent]`, never
  `[projects.<name>.agent]`); getting this wrong makes cc-connect start without an agent for the
  second project. New placeholders use a suffix (`FEISHU_APP_ID_<NAME>`); the user puts the same
  suffixed names, with real values, in the `env` next to that `config.toml`. The workspace for the
  second project is a subdirectory of the existing one (`work_dir = "/workspace/<name>"`); it lives
  on the server, and the `deploy` skill creates and owns it.
- **Same secrets, but a second container** (another agent CLI, its own workspace or limits, or
  isolation from a crash) → no scaffold either: add a second service to the existing instance's
  `docker-compose.yaml` with `<<: *agentbox`, its own `container_name`, config file and volumes,
  sharing `./env`. `docs/INSTANCES.md` §1 has the table.
- **Different secrets, repo, or team** → new instance. Continue with Step 2.

When in doubt, prefer the new instance: cross-domain calls are meant to have friction.

## Step 2: scaffold

```bash
.claude/skills/new-instance/scripts/scaffold.sh [--host <host>] [--agent pi] <name>
```

- The deploy repo is `deploy-repo/` at the agentbox root
  (`.claude/skills/deploy/references/deploy-repo.md`). If it is missing the script exits 2: tell
  the user to clone the private deploy repository there (or `git init deploy-repo` for a brand-new
  one) and stop; do not pick a path yourself.
- `--host` names the directory under `hosts/`, default `default`. A missing `hosts/<host>/host.env`
  or `defaults.env` is laid out from the templates with `xxxx` values; an existing one is never
  touched.
- `<name>` is lowercase letters, digits and dashes. It becomes the service name, the container
  name `agentbox-<name>`, the instance directory `hosts/<host>/instances/<name>/` and the compose
  project name (so the volumes are `<name>_state` / `<name>_cache` on the server).
- `--agent pi` sets `agent.type = "pi"`, uncomments `PI_KEY` in `env` and switches the image in
  `docker-compose.yaml` to the `-pi` tag. Default is `claudecode`.
- File credentials (kubeconfig, ssh keys, cloud CLI profiles) are not a scaffold option. The
  scaffolded `docker-compose.yaml` already mounts `./home:/agent/home:ro`; lay the files out under
  the instance's `home/` like `~` (`docs/CREDENTIALS.md` §2) and the entrypoint copies them into
  place at every start. No path variable is written into the config.
- The script refuses to overwrite an existing instance (exit 1) and prints nothing on stdout;
  stderr ends with the list of files that still need values. Run with `--dry-run` first if you
  want to show the user the plan.

The instance's `docker-compose.yaml` is cut from `examples/demo/docker-compose.yaml`: the shared
block (`x-agentbox`) is the deploy skill's policy and `deploy plan` refuses a file that drops any
of it, so edit only the service's own mounts. The root `docker-compose.yaml` is the local
development file and is not touched. `examples/` holds the demo template and reference examples
only; a scaffolded instance never lands there.

## Step 3: hand off

Read `references/checklist.md` and give the user the steps they must do themselves: filling in
the files the script listed, setting `allow_from` to explicit ids, committing the deploy repo, and
verifying the model gateway. Workspace ownership, the `agentbox` network and starting the service
are the `deploy` skill's job, not a manual step; point the user at it rather than describing them
as something to do by hand. Do not do the human steps for them, and do not put placeholders for
real values into the chat; the values go straight from the user into the files in the deploy
repo.

## Guardrails

- Never write, request, echo or guess a real secret value. Templates hold `xxxx` shapes only;
  `scripts/test.sh` fails on anything else and `docs/CREDENTIALS.md` §5 explains why.
- Leave the README mount contract table, `entrypoint.sh` and the demo example alone. The demo is
  the template every scaffold copies from, `examples/demo/docker-compose.yaml` included: its
  shared block must stay in step with `deploy.sh`'s `check_compose`, and `scripts/test.sh` checks
  both.
- `allow_from = "*"` and `mode = "bypassPermissions"` together let anyone who can message the bot
  read every secret in the container. If the user wants either, say so once and keep the template's
  defaults unless they confirm.
- Finish with `make check` in agentbox; the scaffold and its template are covered by `scripts/test.sh`.

## Final message format

```
Created in deploy-repo/:
- defaults.env                                    (new, fill in)   # only when created
- hosts/<host>/host.env                           (new, fill in)   # only when created
- hosts/<host>/instances/<name>/docker-compose.yaml   (image tag ...)
- hosts/<host>/instances/<name>/config.toml           (agent.type = ...)
- hosts/<host>/instances/<name>/env                   (0600, fill in)

Your steps: (from references/checklist.md, numbered)
```
