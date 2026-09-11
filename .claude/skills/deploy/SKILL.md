---
name: deploy
description: Publish agentbox instances to a remote docker host from the private deploy repository. Use this whenever the user wants to deploy, publish, release, restart or update an agent on a server, or asks what is currently running on a host, including phrasings like "发布到服务器", "上线", "部署一下", "推到生产", "deploy the aliyun agent", "what is running on hk-test". It reads the deploy repo path from the skill's gitignored .env and every host detail from that repo, so no addresses or secrets are typed in chat.
---

# Deploy

`remote-build` is the developer loop; this skill is the release path. Configuration and secrets
live in a separate private repository, one directory per host; images come from GHCR pinned to a
version. The agentbox source tree never reaches the target host.

## Configuration

The deploy repo path lives in `.claude/skills/deploy/.env` (gitignored, template in
`.env.example`). Flags and environment variables override it. If `.env` is missing, do not guess
or ask for a path in chat: point the user at `.env.example` and stop.

Every per-host detail (ssh address, key, proxy, remote directory, target version) lives in the
deploy repo at `hosts/<host>/host.env`. Connection fields stay local; only `AGENTBOX_VERSION` is
derived into the remote `.env`. The version also has a repo-level default in `defaults.env`, so a
fleet moves together from one line while a host that must stay behind keeps its own in `host.env`.

## Actions

```bash
.claude/skills/deploy/scripts/deploy.sh plan   <host> [instance]
.claude/skills/deploy/scripts/deploy.sh deploy <host> [instance]
.claude/skills/deploy/scripts/deploy.sh status <host>
```

- Always run `plan` first and show the user its output. It validates every instance's placeholders
  against its env file, refuses a dirty deploy repo, and lists which containers will restart. It
  never connects, so it is safe at any time.
- `deploy` interrupts any session in progress on the containers it restarts. Omitting `instance`
  restarts every instance on that host. Prefer naming one instance.
- The target version resolves as `--image-version` > that host's `host.env` > the repo's
  `defaults.env`, and `plan` prints which one it used. Upgrading or rolling back is an edit to one
  of those files followed by a deploy, so the deployed version stays readable from git history;
  `--image-version` is for trying a tag once, and never silently becomes the new state.
- `--force` proceeds despite uncommitted changes in the deploy repo. Say once why that is a bad
  idea and keep the default unless the user insists.

## Reading results

On a normal run, the log path is the only thing on stdout; everything else is progress on stderr.
With `-v`, the flag also passes through to `rsync`, so its own file list lands on stdout alongside
the log path. Read the last 40 lines of the log first. A `denied` or `unauthorized` line from the
pull means the server is not logged in to GHCR (`docker login ghcr.io`, a human step). A precheck
line naming unset environment variables means that instance's `env` is incomplete on the server,
which normally cannot happen because `plan` checks it locally first.

Always report which action ran, the host as configured, the version, pass or fail, and the log
path. Never paste the deploy repo's env contents or the full log into the reply.

## Guardrails

- Never write, request, echo or guess a real secret value, and never put a host address in chat.
- Never deploy without showing the user a `plan` first.
- Never sync anything from the agentbox source tree to a target host, and never pull files back.
- The GHCR pull credential is a human step on the server. Do not automate `docker login` and do
  not ask the user for a PAT in chat.
