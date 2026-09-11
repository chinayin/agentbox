# The deploy repository

`deploy.sh` reads and writes a separate, private git repository. This repository holds real
config, real secrets and a per-host commit history; agentbox itself never sees a filled-in `env`
or `config.toml`. Host it on an internal or self-hosted git server, never on a public one
(GitHub included): the secrets are committed in plaintext, so the repository's access control is
the only thing protecting them. This page is what a human reads once, when creating that
repository or adding a new host to it.

## Repository layout

```
agentbox-deploy/
  README.md
  defaults.env
  hosts/
    hk-test/
      host.env
      instances/
        aliyun/{docker-compose.yaml,config.toml,env,kubeconfig}
        demo/{docker-compose.yaml,config.toml,env}
    prod-cn/
      host.env
      instances/...
```

One directory per host under `hosts/`, holding `host.env` (connection info and target version)
and one `instances/<name>/` per instance running there. **Each instance directory is a
self-contained compose project**: its own `docker-compose.yaml`, a filled-in `config.toml` and
`env`, and its file credentials. `deploy.sh` runs `docker compose` from inside that directory on
the server, so the compose project (and the volume prefix) is named after the directory, every
path in the file is relative to it, and moving an instance to another host is moving one directory
(plus its workspace and volumes). There is no host-level compose file; `plan` refuses one.

`config.toml` and `env` here are the real thing — the counterpart of the `config.toml` example and
`env.example` template that `new-instance` generates under `examples/<name>/` in the agentbox
repo. Templates live in agentbox and go in git; real values live in the deploy repo.

## `host.env`

Connection fields (top half) are read locally by `deploy.sh` and never leave this machine. Only
`AGENTBOX_VERSION` (bottom half) is derived into the `.env` that `docker compose` reads on the
server, one copy per instance directory.

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
- `DEPLOY_DIR` is the directory this host's instances live in on the server (see below).
- `AGENTBOX_VERSION` is the only thing an upgrade or rollback touches: edit this line to a
  different tag, then run `deploy`. Omit it and the repo-level `defaults.env` supplies it; keep it
  only for a host that must stay behind the rest of the fleet.

## `defaults.env`

Optional, at the repo root, and read for exactly one variable:

```env
AGENTBOX_VERSION=x.x.x
```

Moving every host to a new image is then this one line rather than one edit per host. Connection
fields are per-host by nature and are never read from here. `--image-version TAG` overrides both
files for a single run, which is how you try a tag without writing it down; the version a host
actually runs stays in git either way, and `plan` prints which source it came from.

## The instance's `docker-compose.yaml`

Generated, not written by hand: `new-instance` and `import-instance` both cut it from
`examples/demo/docker-compose.yaml` in the agentbox repo, so every instance file has the same
shape. Image pinned to a GHCR tag via the version variable that `deploy.sh` writes into the
instance's `.env`; paths relative to the instance directory; the workspace defaults to
`../../workspaces/<name>`, which is `DEPLOY_DIR/workspaces/<name>` on the server:

```yaml
x-agentbox: &agentbox
  image: ghcr.io/<owner>/agentbox:${AGENTBOX_VERSION}
  restart: unless-stopped
  init: true
  stop_grace_period: 30s
  security_opt: [no-new-privileges:true]
  cap_drop: [ALL]
  deploy: {resources: {limits: {pids: 512}}}
  networks: [agentbox]
  env_file: [./env]

services:
  aliyun:
    <<: *agentbox
    container_name: agentbox-aliyun
    volumes:
      - ./config.toml:/agent/config.toml:ro
      - ${WORKSPACES_ROOT:-../../workspaces}/aliyun:/workspace
      - state:/state
      - cache:/cache
      - ./kubeconfig:/agent/kubeconfig:ro

volumes:
  state:
  cache:

networks:
  agentbox:
    external: true
```

The `x-agentbox` block is policy shared by every instance, referenced inside the file by a YAML
anchor rather than inherited from another file, so the directory stays self-contained. `plan`
checks each file for `cap_drop: [ALL]`, `no-new-privileges`, a pids limit, the external network
and `${AGENTBOX_VERSION}`, and refuses `privileged`, `cap_add`, `network_mode` and a docker socket
mount. Edit only the service's own `volumes`; a second container in the same trust domain is a
second service with `<<: *agentbox` and its own `container_name`, config file and volumes
(`docs/MULTI_PROJECT.md` §1).

`deploy.sh` creates the `agentbox` network on the host if it is missing (an idempotent
`docker network inspect || docker network create` before the first `docker compose pull`), so the
external-network declaration works on a fresh host with no manual `docker network create` step.
Every instance on the host joins that one network and containers resolve each other by name; the
repo root's `docker-compose.yaml` stays a development file pointing at a local `agentbox:dev` build.

### Moving from the host-level compose file (before 2026-09-11)

Hosts set up earlier had one `hosts/<host>/docker-compose.yaml` with every instance as a service,
run as one compose project named after `DEPLOY_DIR`. To move such a host: generate or write
`instances/<name>/docker-compose.yaml` for each service, pin each `state` / `cache` volume to the
name the old project gave it (`volumes: state: name: <old-project>_<name>-state`, read it from
`docker volume ls` on the server) so no session history is lost, delete the host-level file, and
commit. Before the first per-instance `deploy`, stop the old project on the server once —
`docker compose -f DEPLOY_DIR/docker-compose.yaml down` (no `-v`) — otherwise the new project's
`container_name` collides with the running container. Then `deploy` as usual and delete the stale
`DEPLOY_DIR/docker-compose.yaml` and `DEPLOY_DIR/.env`.

## Server layout

The server holds only deploy artifacts, no source:

```
/data/agentbox/                       DEPLOY_DIR
  instances/<name>/docker-compose.yaml the instance's compose project; compose runs from this directory
  instances/<name>/.env                written by deploy; compose variables only, no ssh info
  instances/<name>/config.toml         0644, owned by UID 1000
  instances/<name>/env                 0600, owned by UID 1000
  instances/<name>/kubeconfig-*        0600, owned by UID 1000 (file credentials, one file each)
  instances/<name>/ssh_key             0600, owned by UID 1000
  instances/<name>/claude/             read-only managed layer for /etc/claude-code (skills, lock)
  workspaces/<name>/                   created and chowned to UID 1000 by deploy
```

`state` and `cache` are docker named volumes (`<name>_state`, `<name>_cache`), not part of this
tree; a deploy never touches them and `remove` leaves them behind on purpose — the state volume
carries session history and tool-written credentials, and neither a redeploy nor a retirement may
wipe it without a human running `docker volume rm`.

`instances/` on the server mirrors the repo (`rsync --delete`). A directory deleted from the repo
must be retired with `deploy.sh remove <host> <name>` before the next deploy: it stops the
containers through the server's copy of the compose file, then deletes the directory. A plain
deploy refuses while the server holds an instance the repo no longer has, because mirroring the
compose file away would leave running containers with nothing to `down` them.

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
