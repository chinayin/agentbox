# Post-scaffold checklist (the user's steps)

Everything below touches real credentials or a running host, so it stays with the user. Number the
steps in the final message and keep the wording; each one exists because of a real incident.

1. **Fill in `host.env` and `defaults.env` if the script created them.** `host.env` is this
   host's ssh address, key, proxy and remote directory, plus its mirror profile and time zone;
   behind a rule-based proxy write the host as `<ip>.sslip.io` and set the alias to the bare ip
   (`.claude/skills/deploy/references/deploy-repo.md`). `defaults.env` is the image tag from the
   GitHub releases page. Both hold `xxxx` shapes until edited; `deploy plan` only checks that every
   placeholder has some value, so a forgotten `xxxx` is caught by the bot failing to connect, not
   by `plan`.
2. **Fill in the values.** The `env` next to `config.toml` is the real file, already `0600`.
   Every `${NAME}` in `config.toml` must have a value in `env`. Use a
   budgeted virtual key for `ANTHROPIC_AUTH_TOKEN`, not a master key (`docs/CREDENTIALS.md` §1).
3. **Set `ALLOW_FROM` and `ADMIN_FROM` to explicit open_ids.** open_id is per user × app: ids taken
   from another chat app never match, and `"*"` lets anyone drive the agent.
4. **File credentials.** Lay them out under `deploy-repo/hosts/<host>/instances/<name>/home/` exactly as
   they sit in a home directory (`home/.kube/config`, `home/.ssh/config`, `home/.ssh/<key>`),
   `chmod 600`; `deploy` sets the owner. The entrypoint copies them into the container's home at
   every start (`docs/CREDENTIALS.md` §2), so no path variable is needed.
5. **Commit the deploy repo, then let `deploy` do workspace, network and start.** `plan` refuses
   a dirty repo, so commit first. Creating the workspace directory
   and chowning it to UID 1000, creating the `agentbox` network on a host's first instance, and
   running `docker compose up -d` are no longer manual steps — the `deploy` skill
   (`.claude/skills/deploy/SKILL.md`) does all three. Run `plan <host> <name>` first and read its
   output, then `deploy <host> <name>`; it reads back the precheck itself and reports pass or
   fail.
6. **Verify the gateway before blaming the bot.** Claude Code hangs silently on a wrong host or
   key. Run the curl from `docs/CREDENTIALS.md` §7 inside the container (`ANTHROPIC_MODEL` must be set
   for that command); a `content` field in the response means the pair works.
7. **pi only.** `agent.type = "pi"` needs the `-pi` image (the scaffolded `docker-compose.yaml`
   already points at it) and `PI_KEY` in `env`. A pi session has not yet been verified end to end in
   this repo (`docs/ROADMAP.md`), so expect to debug.
