# The deploy repository

`deploy.sh` reads and writes a separate, private git repository (suggested name
`agentbox-deploy`). This repository holds real config, real secrets and a per-host commit
history; agentbox itself never sees a filled-in `env` or `config.toml`. This page is what a human
reads once, when creating that repository or adding a new host to it.

## Repository layout

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

One directory per host under `hosts/`. Each host directory is a self-contained compose project:
its own `host.env` (connection info and target version), its own `docker-compose.yaml`, and one
`instances/<name>/` per agent running there, holding a filled-in `config.toml` and `env`.

`config.toml` and `env` here are the real thing — the counterpart of the `config.toml` example and
`env.example` template that `new-instance` generates under `examples/<name>/` in the agentbox
repo. Templates live in agentbox and go in git; real values live in the deploy repo.

## `host.env`

Connection fields (top half) are read locally by `deploy.sh` and never leave this machine. Only
`AGENTBOX_VERSION` (bottom half) is derived into the remote `.env` that `docker compose` reads on
the server.

```env
DEPLOY_HOST=root@xxx.xxx.xxx.xxx.sslip.io
DEPLOY_KEY=~/.ssh/xxxx.pem
DEPLOY_HOST_KEY_ALIAS=xxx.xxx.xxx.xxx
DEPLOY_SOCKS=127.0.0.1:7890
DEPLOY_DIR=/data/agentbox

# Derived into the remote .env; nothing else in this file is.
AGENTBOX_VERSION=x.x.x
```

- `DEPLOY_HOST` / `DEPLOY_KEY` / `DEPLOY_HOST_KEY_ALIAS` / `DEPLOY_SOCKS` follow the same shape as
  `remote-build`'s `.env.example`, because the network path is the same: behind a rule-based proxy
  a bare IP goes DIRECT and times out, so use the `<ip>.sslip.io` form and set the alias to the
  real IP to keep `known_hosts` correct.
- `DEPLOY_DIR` is the directory this host's compose project lives in on the server (see below).
- `AGENTBOX_VERSION` is the only thing an upgrade or rollback touches: edit this line to a
  different tag, then run `deploy`.

## Production `docker-compose.yaml`

Written by hand in the deploy repo, one per host, image pinned to a GHCR tag via the version
variable that `deploy.sh` writes into the remote `.env`:

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
volumes:
  aliyun-state:
  aliyun-cache:
```

This file is not generated. Paste in the service block that `new-instance`'s scaffold script
prints, then swap the image line for the GHCR form above — the repo root's `docker-compose.yaml`
stays a development file pointing at a local `agentbox:dev` build; the two never share content or
generate one another.

## Server layout

The server holds only deploy artifacts, no source:

```
/data/agentbox/                       DEPLOY_DIR
  docker-compose.yaml
  .env                                 written by deploy; compose variables only, no ssh info
  instances/<name>/config.toml         0644, owned by UID 1000
  instances/<name>/env                 0600, owned by UID 1000
  instances/<name>/kubeconfig-*        0600, owned by UID 1000 (file credentials, one file each)
  instances/<name>/ssh_key             0600, owned by UID 1000
  instances/<name>/claude/             read-only managed layer for /etc/claude-code (skills, lock)
  workspaces/<name>/                   created and chowned to UID 1000 by deploy
```

`state` and `cache` are docker named volumes, not part of this tree; a deploy never touches them.
That is deliberate — the state volume carries session history and tool-written credentials, and a
redeploy must not wipe it.

### Why the deploy directory itself is created `0700`

`sync_host` in `deploy.sh` creates `DEPLOY_DIR` with `install -d -m 0700` before rsyncing into it.
`rsync -a` preserves each source file's mode, so an instance's `env` file can land on disk
world-readable for the brief window between the rsync and the `chmod 600` that follows it. Closing
the parent directory to the owner means that window never actually exposes a secret to another
unprivileged user on the host, no matter what mode a file arrives with.

This is safe under the deployment shape this skill assumes: an ssh login that owns `DEPLOY_DIR`,
plus a standard root `dockerd`. `dockerd` resolves bind-mount sources as root regardless of the
directory's own permission bits, and what a container can read is governed by the mount target's
mode inside the container, not by who else on the host can traverse `DEPLOY_DIR`.

**It would break under rootless dockerd, or under any setup where a different, non-owning,
non-root user needs to run `docker compose` against this tree** — that user would be locked out by
the same `0700` that is protecting everyone else. If a deploy fails on a rootless host for reasons
that look like a permissions problem on `DEPLOY_DIR` itself, this is why; it is not covered by
today's design and needs a rethink, not a chmod worked around by hand.

### Why `config.toml` and `env` do not share a mode

`config.toml` is bind-mounted read-only into the container (`config.toml:/agent/config.toml:ro`),
so it keeps whatever host uid/gid/mode it arrives with, and the agent process — UID 1000 inside
the container — must be able to read it. That is why it stays world- or group-readable (`0644`)
rather than being tightened.

`env`, by contrast, is never mounted into the container at all: `docker compose` reads it
host-side, through `env_file:`, before the container starts. Nothing inside the container ever
opens it, so it can be — and is — tightened to `0600` and owned by UID 1000 the moment it lands.

The two files carrying different modes is not an inconsistency to fix; it follows from one being
read by the container and the other only ever being read by compose on the host.

File credentials (`kubeconfig-*`, `ssh_key`) follow `env`: 0600 and owned by UID 1000, because the container reads them through a bind mount as that UID and nothing else on the host should. `claude/` is code, not credentials, and keeps the modes it arrived with. `deploy` applies all of this on every run, so an instance written by `import-instance` needs no manual chmod on the server.
