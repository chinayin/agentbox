---
name: remote-build
description: Build and smoke-test the agentbox images on a remote docker host instead of this machine. Use it whenever the user wants to build, rebuild, verify, or smoke the image and the local network is slow or blocked, or whenever they say "remote build", "远端构建", "在构建机上跑", "build on the server", or ask to check whether a toolchain change actually installs. Also use it to probe the build host (reachability, docker, egress) before a long build. It reads the host from the skill's gitignored .env, so no addresses need to be typed.
---

# Remote build

The official images come from CI on a git tag; this skill is the developer loop before that. It
rsyncs the working tree to a docker host with good egress, runs `make image` / `make smoke` there
and tees the log back into `runtime/remote-build/`. Secrets (`.env`, `examples/*/env`, the skill
`.env` files) are excluded from the sync.

## Configuration

The host lives in `.claude/skills/remote-build/.env` (gitignored, template in `.env.example`).
Flags and environment variables override it. If `.env` is missing, do not guess or ask the user
for an address in chat: point them at `.env.example` and stop. Host addresses and key paths are
topology information (`docs/SECRETS.md` S2) and stay out of the repo and the transcript.

Behind a rule-based proxy such as Clash, a bare IP goes DIRECT and times out; `.env.example`
shows the `<ip>.sslip.io` + host-key-alias form that forces the SOCKS path.

## Actions

```bash
.claude/skills/remote-build/scripts/remote-build.sh probe     # reachability, docker, egress to upstream hosts
.claude/skills/remote-build/scripts/remote-build.sh build     # sync + make image (both images)
.claude/skills/remote-build/scripts/remote-build.sh smoke     # sync + make image + make smoke
.claude/skills/remote-build/scripts/remote-build.sh shell     # sync, then an interactive shell in the remote repo dir
```

- Start with `probe` when the host has not been used today or a build just failed with a network
  error. Its egress table shows which upstream (github, dl.google.com, nodejs.org, get.helm.sh,
  dl.k8s.io) is slow or blocked; a lock refresh or image build that hangs on one of them is a
  host problem, not a lock problem.
- `smoke` is the answer to "does this toolchain change really install": smoke checks every locked
  tool inside the running image (`docs/TOOLCHAIN.md` §4 step 4).
- `--platform linux/arm64` cross-builds through QEMU; slow, and only worth it when closing
  `docs/ROADMAP.md` item 1.
- `--dry-run` prints the plan without connecting; use it to show the user what will run.

## Reading results

The script prints the log path on stdout when a remote make succeeds and exits 1 on failure with
the path on stderr. Read the last 40 lines of the log first: a `mise install` failure names the
tool and URL; a smoke failure prints `[FAIL]` lines with the check name. Do not retry blindly;
`references/troubleshooting.md` maps the common failures to their cause.

Always report which action ran, the host (as configured, not expanded), pass/fail, and the log
path. Never paste the `.env` contents or the full log into the reply.
