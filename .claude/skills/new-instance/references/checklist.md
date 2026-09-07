# Post-scaffold checklist (the user's steps)

Everything below touches real credentials or a running host, so it stays with the user. Number the
steps in the final message and keep the wording; each one exists because of a real incident.

1. **Create the secret file.** `cp examples/<name>/env.example examples/<name>/env && chmod 600
   examples/<name>/env`. The `env` file is gitignored; `env.example` is what gets committed.
2. **Fill in the values.** Every `${NAME}` in `config.toml` must have a value in `env`. Use a
   budgeted virtual key for `ANTHROPIC_AUTH_TOKEN`, not a master key (`docs/SECRETS.md` §1).
3. **Set `ALLOW_FROM` and `ADMIN_FROM` to explicit open_ids.** open_id is per user × app: ids taken
   from another chat app never match, and `"*"` lets anyone drive the agent.
4. **File credentials.** For each `--mount FILE`, place the file at `examples/<name>/FILE` with
   `chmod 600` and an owner matching the image's `AGENT_UID` (default 1000).
5. **Workspace owner.** `runtime/workspaces/<name>` (or `$WORKSPACES_ROOT/<name>`) must be
   writable by UID 1000. Docker creates a missing bind-mount directory as root, which is why the
   scaffold created it first.
6. **Network exists once per host.** `docker network create agentbox` if this is the first
   instance on the machine; compose declares it as external.
7. **Start and read the precheck.** `docker compose up -d <name> && docker compose logs <name>`.
   Exit code 2 with a list of names means unset placeholders; fix `env`, not `config.toml`.
8. **Verify the gateway before blaming the bot.** Claude Code hangs silently on a wrong host or
   key. Run the curl from `docs/TOOLS.md` §3a inside the container (`ANTHROPIC_MODEL` must be set
   for that command); a `content` field in the response means the pair works.
9. **pi only.** `agent.type = "pi"` needs the `-pi` image (the snippet already uses
   `AGENTBOX_IMAGE_PI`) and `PI_KEY` in `env`. A pi session has not yet been verified end to end in
   this repo (`docs/ROADMAP.md`), so expect to debug.
