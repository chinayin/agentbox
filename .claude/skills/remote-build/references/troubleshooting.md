# Remote build troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `cannot reach <host> over SSH` on every port, ICMP too | Carrier drops direct traffic to the host's range (seen on mobile lines); not a security-group issue | Set `AGENTBOX_REMOTE_SOCKS` and write the host as `<ip>.sslip.io` with `AGENTBOX_REMOTE_HOST_KEY_ALIAS=<ip>` |
| SOCKS configured but connection still times out | Rule-based proxy sends bare IPs DIRECT | Use the `.sslip.io` hostname form; the alias keeps `known_hosts` keyed by the real ip |
| `Permission denied (publickey)` | Wrong key path, or `~` not expanded when the path came from the environment | Use the `.env` (it expands a leading `~/`) or an absolute path |
| `no docker on the remote` | Fresh host | Install docker with buildx on the host; the repo deliberately ships no host bootstrap (`docs/ROADMAP.md`, rejected items) |
| probe egress shows `000` or long `time_total` for one upstream | That upstream is blocked or throttled from the host | Build waits or fails on that tool only; try later or use `make image BUILD_HTTPS_PROXY=...` on the host (`docs/CN_MIRRORS.md` §1) |
| `mise install` fails with a checksum or 404 | Lock is stale for that tool | Run `make lock-refresh` locally, review the diff, re-sync; never edit the lock by hand |
| smoke `[FAIL]` on a tool version | Image built from an older sync or a stale layer | Re-run `build` (rsync `--delete` is on); check the lock line for that tool in the log |
| rsync complains about `ProxyCommand` | rsync `-e` takes one string | The script writes a wrapper for ssh options; do not pass `-e` yourself |
| Remote `make smoke` passes but a real instance misbehaves | Smoke uses bare `docker run`, not compose | Compose hardening is untested by smoke (`docs/ROADMAP.md` item 6); inspect the running container |
