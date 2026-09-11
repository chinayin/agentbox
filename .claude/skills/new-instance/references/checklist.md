# Post-scaffold checklist (the user's steps)

Everything below touches real credentials or a running host, so it stays with the user. Number the
steps in the final message and keep the wording; each one exists because of a real incident.

1. **Copy the template into the deploy repo.** `examples/<name>/` is a template, not a running
   instance: copy the whole directory (`docker-compose.yaml` included) into the private deploy
   repository at `hosts/<host>/instances/<name>/` (see
   `.claude/skills/deploy/references/deploy-repo.md`), rename `env.example` to `env` there, and
   `chmod 600` it. Fill in the real values in the deploy repo, not in this one. The directory is
   the whole instance: nothing else in the deploy repo needs editing.
2. **Fill in the values.** Every `${NAME}` in `config.toml` must have a value in `env`. Use a
   budgeted virtual key for `ANTHROPIC_AUTH_TOKEN`, not a master key (`docs/SECRETS.md` §1).
3. **Set `ALLOW_FROM` and `ADMIN_FROM` to explicit open_ids.** open_id is per user × app: ids taken
   from another chat app never match, and `"*"` lets anyone drive the agent.
4. **File credentials.** For each `--mount FILE`, place the file at
   `hosts/<host>/instances/<name>/FILE` in the deploy repo with `chmod 600` and an owner matching
   the image's `AGENT_UID` (default 1000).
5. **Workspace, network, start: now the `deploy` skill's job.** Creating the workspace directory
   and chowning it to UID 1000, creating the `agentbox` network on a host's first instance, and
   running `docker compose up -d` are no longer manual steps — the `deploy` skill
   (`.claude/skills/deploy/SKILL.md`) does all three. Run `plan <host> <name>` first and read its
   output, then `deploy <host> <name>`; it reads back the precheck itself and reports pass or
   fail.
6. **Verify the gateway before blaming the bot.** Claude Code hangs silently on a wrong host or
   key. Run the curl from `docs/TOOLS.md` §3a inside the container (`ANTHROPIC_MODEL` must be set
   for that command); a `content` field in the response means the pair works.
7. **pi only.** `agent.type = "pi"` needs the `-pi` image (the scaffolded `docker-compose.yaml`
   already points at it) and `PI_KEY` in `env`. A pi session has not yet been verified end to end in
   this repo (`docs/ROADMAP.md`), so expect to debug.
