# OpenClaw Stack — Security Convergence Log

> Last updated: 2026-04-15

## Guiding principle

This is not about adding features. It is about **shrinking entry points, pinning high-risk capabilities behind narrow interfaces, and further compartmentalising secrets and deployment authority.**

OpenClaw's own threat model assumes one trusted operator per gateway. It is *not* intended to be a multi-tenant security boundary, and it was never treated as one here.

---

## The 9-item convergence checklist

### [x] 1. Shrink the gateway's external exposure
- **Status: complete**
- `docker-compose.yml` port mapping changed from `"8080:18789"` to `"127.0.0.1:8080:18789"`.
- The gateway now binds to 127.0.0.1 only; outside networks cannot reach it directly.
- Verified: local 200, external 000, inter-container 200.

### [x] 2. Keep the gateway away from the Docker socket
- **Status: complete (intentional from day one)**
- The gateway container has no Docker CLI and no `/var/run/docker.sock` mount.
- This red line is permanent — it is the difference between "compromised gateway" and "compromised host."

### [x] 3. Bridge scripts are single-purpose
- **Status: complete**
- `run-codex.sh` — prompt is piped over stdin (prevents shell-injection via argv expansion), length capped at 4 000 chars, container and working directory are hard-coded.
- `deploy-staging.sh` — zero arguments, every step hard-coded, no path to production.
- `query-readonly.sh` — `SELECT`/`WITH` only, blocks 12 dangerous keywords, auto-appends `LIMIT 100`, query passed via stdin.

### [x] 4. Codex stays non-interactive / automation-only
- **Status: complete**
- `CODEX_API_KEY` is injected via `.env` (file mode 600, owner-only).
- No interactive login token exists inside the container.
- codex-cli 0.120.0 is invoked via `codex exec` in non-interactive mode.
- Future improvement: migrate to Docker secrets instead of env files.

### [x] 5. Deploy path is staging-only for now
- **Status: complete**
- `deploy-staging.sh` is locked to zero arguments and a fixed staging target.
- There is no production deployment path anywhere in the stack.

### [x] 6. DB queries are read-only, time-bounded, row-bounded
- **Status: complete**
- `query-readonly.sh` enforces: `SELECT` only, `LIMIT 100`, blocks DDL/DML.
- TODO: once wired to a real database, add `statement_timeout` and a fixed `search_path`.

### [x] 7. Formal Telegram config + allowlist before activation
- **Status: complete**
- `openclaw.json` now contains a `channels.telegram` block.
- `dmPolicy: allowlist`, `allowFrom` restricted to the operator's user ID.
- `groupPolicy: allowlist`, `groups: {}` (empty until groups are explicitly added).
- `enabled: false` — Telegram remains off until all other items are locked down.
- `requireMention: true` — in groups the bot must be @-mentioned.

### [x] 8. Rotate every credential that was ever exposed
- **Status: complete**
- Gateway auth token rotated.
- Telegram bot token revoked and reissued via `@BotFather /revoke`.
- `CODEX_API_KEY` was never exposed, so it was not rotated.
- Temporary files containing the old tokens have been removed.

### [x] 9. OpenClaw → Bridge integration
- **Status: complete (2026-04-15)**
- Added an `openclaw-bridge` container: `docker:27-cli` base + `python3`, a three-route `http.server` with no dynamic dispatch:
  - `POST /run-codex` (timeout 600 s)
  - `POST /deploy-staging` (timeout 900 s)
  - `POST /query-readonly` (timeout 30 s)
- Bearer-token auth. `BRIDGE_TOKEN` lives in `/opt/openclaw-stack/bridge/.env` (chmod 600).
- New docker network `openclaw-internal` with `internal: true`. Both gateway and bridge join it; no host port is published.
- Bridge listens on `0.0.0.0:8005` inside its own container only — not reachable from the host.
- Bridge container runs with `read_only: true` + `tmpfs: /tmp`; the only writes possible are to tmpfs.
- Only three things are mounted into bridge: `/var/run/docker.sock`, and each worker script as `:ro`.
- Gateway side is rewritten as thin clients (`bridge-client.js` plus three shell wrappers), because the gateway container has no Docker CLI and no `curl`/`wget` — only `node`.
- Worker script locations:
  - `/opt/openclaw-stack/bridge/scripts/run-codex.sh`
  - `/opt/openclaw-stack/deploy-runner/scripts/deploy-staging.sh`
  - `/opt/openclaw-stack/db-query-runner/scripts/query-readonly.sh`
- Verification: `healthz` returns 200; missing token returns 401; a valid `SELECT` round-trips; `UPDATE` is rejected; the zero-arg deploy runs; an empty prompt is rejected; the bridge publishes no host port.

---

## File reference

| Path | Role |
|------|------|
| `/opt/openclaw-stack/docker-compose.yml` | Main orchestration |
| `/opt/openclaw-stack/gateway/config/openclaw.json` | Gateway + Telegram config (not committed) |
| `/opt/openclaw-stack/gateway/config/run-codex.sh` | Codex bridge client (gateway side) |
| `/opt/openclaw-stack/gateway/config/deploy-staging.sh` | Deploy bridge client (gateway side) |
| `/opt/openclaw-stack/gateway/config/query-readonly.sh` | DB query bridge client (gateway side) |
| `/opt/openclaw-stack/gateway/config/bridge-client.js` | Node thin HTTP client |
| `/opt/openclaw-stack/bridge/server.py` | Bridge HTTP server (token auth, 3 fixed routes, port 8005) |
| `/opt/openclaw-stack/bridge/Dockerfile` | Bridge container image |
| `/opt/openclaw-stack/bridge/.env` | `BRIDGE_TOKEN` (chmod 600, not committed) |
| `/opt/openclaw-stack/bridge/scripts/run-codex.sh` | Codex worker script (runs inside bridge) |
| `/opt/openclaw-stack/deploy-runner/scripts/deploy-staging.sh` | Deploy worker script |
| `/opt/openclaw-stack/db-query-runner/scripts/query-readonly.sh` | DB query worker script |
| `/opt/openclaw-stack/codex-worker/.env` | `CODEX_API_KEY` (chmod 600, not committed) |
