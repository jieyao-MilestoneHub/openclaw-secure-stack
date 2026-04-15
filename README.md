# OpenClaw Secure Stack

A security-hardened automation pipeline that connects **Telegram → OpenClaw Gateway → a narrow HTTP bridge → three single-purpose worker containers** (Codex for code changes, a staging deployer, and a read-only DB querier).

The focus of this repository is **defense-in-depth**, not features. Every component is designed to *shrink entry points* and *narrow high-risk capabilities* rather than grow them.

---

## Architecture

```
                    ┌─────────────────────┐
                    │  Telegram (user)    │
                    │  allowlist: 1 user  │
                    └──────────┬──────────┘
                               │ HTTPS (botToken)
                               ▼
          ┌─────────────────────────────────────┐
          │  OpenClaw Gateway                   │
          │  listens on 127.0.0.1:8080 ONLY     │
          │  no docker socket · token auth      │
          │  networks: default + openclaw-int   │
          └───────┬─────────────────────────────┘
                  │ HTTP  Bearer token (BRIDGE_TOKEN)
                  │ over openclaw-internal (internal: true)
                  ▼
          ┌─────────────────────────────────────┐
          │  Bridge (python http.server)        │
          │  3 fixed routes, no dynamic dispatch│
          │  read_only rootfs · tmpfs /tmp      │
          │  mounts /var/run/docker.sock        │
          └────┬────────┬────────────┬──────────┘
               │        │            │
          docker exec (via socket, fixed container names)
               │        │            │
               ▼        ▼            ▼
       codex-worker  deploy-runner  db-query-runner
       (codex exec   (staging only, (SELECT only,
        in fixed      zero-arg,      LIMIT 100,
        workspace)    placeholder)   keyword block)
```

All external traffic terminates at gateway on `127.0.0.1:8080`. Bridge is only reachable from gateway over an `internal: true` docker network — no host port, no egress.

---

## Design principles

1. **One entry point per boundary.** Telegram is the only user surface. Gateway is the only thing that talks to bridge. Bridge is the only thing that holds the docker socket.
2. **Narrow, fixed interfaces — not general executors.** Bridge exposes exactly 3 POST routes, each wired to exactly one hardened shell script. No arbitrary command execution, no parametrised container names.
3. **Validate at every layer.** HTTP body size + JSON schema (bridge), keyword/length checks (scripts), allowlist (Telegram).
4. **Assume the token leaks.** Every legitimate call path still has the next layer of validation; legitimate-but-abusive requests are still bounded (SELECT-only, zero-arg deploy, prompt-length cap).
5. **Read-only everywhere we can.** Bridge rootfs is read-only; script mounts are `:ro`; backups are not kept.

---

## Quick start

```bash
# 1. Clone
git clone git@github.com:jieyao-MilestoneHub/openclaw-secure-stack.git
cd openclaw-secure-stack

# 2. Generate & fill in secrets
cp bridge/.env.example bridge/.env
openssl rand -hex 32 | sed 's/^/BRIDGE_TOKEN=/' > bridge/.env
chmod 600 bridge/.env

cp codex-worker/.env.example codex-worker/.env
# edit codex-worker/.env → set CODEX_API_KEY
chmod 600 codex-worker/.env

cp gateway/config/openclaw.json.example gateway/config/openclaw.json
# edit openclaw.json → set gateway.auth.token, channels.telegram.botToken, allowFrom
chmod 600 gateway/config/openclaw.json

# 3. (Optional) the Codex worker expects a project checkout at this path:
mkdir -p codex-worker/workspace
git clone <your-project> codex-worker/workspace/finantial-chatbot

# 4. Launch
docker compose up -d
```

Verify:

```bash
# Bridge is healthy (from inside gateway)
docker exec openclaw-gateway sh -c \
  'node -e "require(\"http\").get({host:\"openclaw-bridge\",port:8005,path:\"/healthz\"},r=>r.pipe(process.stdout))"'

# Bridge is NOT reachable from host (expect connection refused / no route)
curl -sS --max-time 3 http://127.0.0.1:8005/healthz && echo LEAK || echo OK
```

---

## Hardening summary

This stack went through a 9-step security convergence. The full record is in [`HARDENING.md`](./HARDENING.md). Summary:

| # | Control | Result |
|---|---|---|
| 1 | Gateway bound to `127.0.0.1` only | ✅ No external port |
| 2 | Gateway has no docker socket | ✅ Enforced |
| 3 | Bridge scripts are single-purpose | ✅ Fixed container/dir/args |
| 4 | Codex runs non-interactive only | ✅ `codex exec` via API key |
| 5 | Deploy path is staging-only | ✅ Zero-arg script |
| 6 | DB queries are read-only + limited | ✅ SELECT/WITH + LIMIT + keyword deny-list |
| 7 | Telegram requires allowlist config | ✅ dmPolicy/groupPolicy allowlist |
| 8 | All leaked credentials rotated | ✅ Done |
| 9 | OpenClaw → Bridge integration | ✅ Narrow HTTP bridge on internal network |

---

## Threat model & known trade-offs

**In-scope threats we defend against:**
- Passive network attacker reaching bridge directly → blocked by `internal: true`.
- Unauthorized Telegram user → blocked by `dmPolicy: allowlist`.
- SQL injection via bridge `/query-readonly` → validated as SELECT/WITH + keyword deny-list.
- Shell injection via prompt → prompt passed over stdin, not argv expansion.

**Known acceptable trade-off:**
- Bridge holds the docker socket. A successful RCE inside bridge is equivalent to host root. This is mitigated — not eliminated — by a read-only rootfs, fixed 3-route dispatch, Bearer token auth, and zero inbound exposure. A future iteration may front it with [`tecnativa/docker-socket-proxy`](https://github.com/Tecnativa/docker-socket-proxy) to allow only `POST /containers/{name}/exec` for specific container names.

**Out of scope:**
- Host-level compromise. If an attacker has root on the host, docker socket is irrelevant — they already own everything.
- Supply-chain attacks on base images. Mitigated by pinning major versions, but not fully addressed.

---

## Repository layout

```
bridge/                   HTTP bridge container
  server.py               Python http.server, 3 routes, Bearer auth
  Dockerfile              docker:27-cli + python3
  .env.example            BRIDGE_TOKEN template
  scripts/run-codex.sh    Worker: docker exec into codex-worker

gateway/
  Dockerfile              OpenClaw gateway image
  config/
    openclaw.json.example Gateway + Telegram config template
    bridge-client.js      Node thin HTTP client
    run-codex.sh          Gateway-side client script
    deploy-staging.sh     Gateway-side client script
    query-readonly.sh     Gateway-side client script

codex-worker/             Runs codex-cli against a project workspace
  Dockerfile
  .env.example            CODEX_API_KEY template

deploy-runner/            Staging deploy container (alpine)
  scripts/deploy-staging.sh

db-query-runner/          Read-only DB query container (alpine)
  scripts/query-readonly.sh

docker-compose.yml        Orchestration + openclaw-internal network
HARDENING.md              Full hardening log (Traditional Chinese)
LICENSE                   MIT
```

---

## Contributing

Security-related issues: please open a GitHub issue marked `[security]` — or, if sensitive, reach the maintainer privately before filing.

---

## License

MIT. See [`LICENSE`](./LICENSE).
