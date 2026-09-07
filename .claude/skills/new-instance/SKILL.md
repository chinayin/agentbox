---
name: new-instance
description: Add a new agentbox instance to this repository. Use this whenever the user wants another agent, bot, team instance, trust domain, or project added to the deployment, even when they only say things like "spin one up for the ops team", "add one more bot", or "put a second project into config.toml". It decides between adding a [[projects]] block to an existing instance and scaffolding a new compose service, generates the config template, env template, workspace directory and compose snippet, and hands back the manual checklist. It never asks for or writes real secret values.
---

# New instance

An agentbox instance is one compose service: one `config.toml`, one env file, one workspace, one
state volume, one cache volume. The repo's rule is **one container per trust domain, not per
project** (`docs/MULTI_PROJECT.md` §1). So the first thing to settle is whether the user needs a
new container at all.

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
- **Different secrets, repo, or team** → new instance. Continue with Step 2.

When in doubt, prefer the new instance: cross-domain calls are meant to have friction.

## Step 2: scaffold

```bash
.claude/skills/new-instance/scripts/scaffold.sh [--agent pi] [--mount kubeconfig] [--mount ssh_key] <name>
```

- `<name>` is lowercase letters, digits and dashes. It becomes the service name, container name
  `agentbox-<name>`, the `examples/<name>/` directory and the `<name>-state` / `<name>-cache`
  volumes.
- `--agent pi` sets `agent.type = "pi"`, uncomments `PI_KEY` in the env template and switches the
  snippet to the `-pi` image. Default is `claudecode`.
- `--mount FILE` adds a read-only file credential at `/agent/FILE` (see `docs/TOOLS.md` §2 for
  which tool reads which path). `kubeconfig` also gets `KUBECONFIG=/agent/kubeconfig` written into
  the config's env block. Anything other than `kubeconfig` / `ssh_key` must be added to
  `.gitignore` under `examples/*/` before the real file is created.
- The script refuses to overwrite an existing `examples/<name>` (exit 1) and never touches
  `docker-compose.yaml`. Run with `--dry-run` first if you want to show the user the plan.

The compose snippet is printed on stdout. Paste the first block under `services:` and the second
under `volumes:` in `docker-compose.yaml`, then confirm the file still parses:

```bash
docker compose config -q
```

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
  the template every scaffold copies from.
- `allow_from = "*"` and `mode = "bypassPermissions"` together let anyone who can message the bot
  read every secret in the container. If the user wants either, say so once and keep the template's
  defaults unless they confirm.
- Finish with `make check`; the scaffolded files are part of the repo and must pass the same gate.

## Final message format

```
Created:
- examples/<name>/config.toml   (agent.type = ..., mounts: ...)
- examples/<name>/env.example
- runtime/workspaces/<name>/

Compose: pasted <name> service + volumes into docker-compose.yaml, `docker compose config -q` passes.

Your steps: (from references/checklist.md, numbered)
```
