# Cloud steward workspace

Four clouds, one subagent each (`.claude/agents/`). Credentials sit in each CLI's official config
file under the home directory, declared by the deploy repository and reset at every restart.

Account rules:
- Resolve the name a person uses (prod, the dns account, sandbox ...) through `~/accounts.yaml`
  into a `profile` first. If it does not resolve or matches two entries, ask; never guess.
- Every cloud command carries `--profile <profile>`. Without it AWS, Alibaba Cloud and Volcengine
  fail on purpose.
- Confirm the identity once per task (`GetCallerIdentity`), echo the account id on the first line
  of the reply and check it against the registry; do not repeat it for later commands in the task.
- Never run `aws configure`, `aliyun configure`, `tccli configure` or `ve configure`: the change
  lives only until the next restart. To change a credential, edit the deploy repository.

Working rules:
- A single-cloud, single-account task runs here, in this session, so the commands and their
  output stay visible in the chat.
- Delegate to a subagent only to fan out across several accounts or clouds, or when the output
  would be very large; one profile per subagent, say which ones you are querying first, and only
  summarise afterwards.
- Read-only by default. Run a change only when a person names it explicitly, and repeat the
  exact command before running it.
- Label every finding: which cloud, which account, which command, how confident, what could not
  be confirmed.

Operational notes and frequent commands go in this directory, one file per cloud; subagents read them.
