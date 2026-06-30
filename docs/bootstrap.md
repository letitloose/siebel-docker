# Bootstrapping the Siebel Enterprise

This document explains what `scripts/bootstrap-mde.sh` does, why it's built the way it is, and how it maps back to the original Ansible playbook (`0031_siebel_docker_2411_deploy_full_stack_mde.yml`, referred to as "0004" earlier in this project).

## What "bootstrap" means here

Building the four Siebel images (CGW, SES, SAI, MDE) and starting them as containers gets you Siebel *installed*. It does not get you Siebel *running* — no gateway registry exists yet, no enterprise is configured, and no application is deployed. That configuration work is what the original Ansible playbook's deploy step did by calling the Siebel Cloud Gateway's REST management API, and it's what `bootstrap-mde.sh` replicates.

The Cloud Gateway API is a JSON/HTTPS API served by Tomcat inside the MDE container at `https://<host>:<port>/siebel/v1.0/`. It is not exposed by any other component — it's how administrative tools (and our script) configure the enterprise without needing direct shell access to Siebel's binaries.

## Why a host-side script instead of a container

Everything the script needs is already reachable from the host:

- `docker compose exec` only works from the host (or somewhere with the Docker socket) — there's no way to call it from inside another container without mounting the Docker socket, which adds complexity for no benefit here
- The MDE container already publishes its Cloud Gateway API port to the host (`4443:6091` in `docker-compose.yml`), so `curl` can reach it at `https://localhost:4443` without any extra networking
- `curl` and `bash` are available on essentially every Linux/macOS dev machine — no new Docker image, no new compose service, nothing to build

This keeps the bootstrap step as a single, readable script instead of a containerized tool with its own image and lifecycle.

## What the script does, in order

**1. Start MDE's Tomcat services**
```bash
docker compose exec -T --workdir /config mde ./start_ai_internal.sh
docker compose exec -T --workdir /config mde ./start_ai_external.sh
```
These are the same scripts described in [docs/images/mde.md](images/mde.md). The "internal" Tomcat hosts the gateway and Siebel Server admin interface (on the SES port range); the "external" Tomcat hosts the Application Interface and the Cloud Gateway REST API (on the AI port range, published as 4443).

**2. Wait for the REST API to respond**
A simple polling loop (`curl -o /dev/null`) waits until the API answers, since Tomcat takes a few seconds to start.

**3–9. The REST API sequence**
Each step is a `POST` to a specific Cloud Gateway endpoint, authenticated with HTTP basic auth (`AI_USERNAME`/`AI_USER_PWD`, which is `SADMIN` and its password). The `api()` helper function in the script wraps `curl` so every call looks the same: method, path, JSON body.

| # | Endpoint | Purpose |
|---|---|---|
| 1 | `POST /cginfo` | Tells the gateway its own hostname and TLS port |
| 2 | `POST /cloudgateway/GatewaySecurityProfile` | Configures DB-backed authentication for the gateway — which database, which table owner, test credentials |
| 3 | `POST /cloudgateway/bootstrapCG` | Creates the gateway registry itself, with a registry port and admin credentials |
| 4 | `POST /cloudgateway/profiles/enterprises/` | Creates an **Enterprise profile** — a template defining the SFS path, DB connection, and PKI keystore/truststore settings |
| 5 | `POST /cloudgateway/profiles/servers/` | Creates a **Server profile** — which Siebel component groups to enable (Call Center, EAI, Workflow, etc.) and server-level encryption settings |
| 6 | `POST /cloudgateway/profiles/swsm/` | Creates an **AI profile** — session timeouts, REST inbound settings, and which Siebel applications (`eai`, `callcenter`, `publicsector`) are exposed through the web tier |
| 7 | `POST /cloudgateway/deployments/enterprises/` | **Deploys** the Enterprise profile — this is what actually creates the enterprise in the gateway registry. Polled until `Status: "Deployed"` |
| 8 | `POST /cloudgateway/deployments/servers/` | **Deploys** the Server profile to the MDE host. Polled until deployed |
| 9 | `POST /cloudgateway/deployments/swsm/` | **Deploys** the AI profile. Once this finishes, the Siebel web UI is reachable |

Profiles vs. deployments is the same pattern throughout: a profile is a reusable config template; a deployment applies a named profile to a specific physical host. Since our entire stack lives in one MDE container, every deployment in this script targets `${MDE_HOSTNAME}.${PKI_DOMAIN}`.

## Differences from the Ansible original

- **Trimmed AI profile.** The original AI profile (`siebel-profile-sai-mde-docker`) configured five application entries, including an LDAP-authenticated variant (`finsldap`) and a French-language `callcenter` variant. Our script keeps the three applications that match what the Server profile actually enables: `eai`, `publicsector`, `callcenter`. Add more entries to the `Applications` array in the script if you need them.
- **Hardcoded internal names.** Profile names (`enterprise_profile`, `server_profile`, `ai_profile`), node names (`siebses1`, `siebsai1`), and the database usernames `SIEBEL_TABLEOWNER`/`SIEBEL_ANON_USER` (`SIEBEL`/`GUESTCST`) are constants at the top of the script rather than `.env` variables. Their corresponding database users are created with these exact literal names in `01-setup.sql.template` — changing the constant wouldn't rename the DB user, so making them `.env` variables would only create the appearance of configurability without the substance. The *passwords* for these accounts remain real `.env` variables (`SIEBEL_ANON_PWD`) since those genuinely flow through to `ALTER`/`CREATE USER` statements.
- **No `mwadm`/cluster setup.** Ansible's server profile task included a large commented-out list of alternate component group combinations for different deployment types (CRM, loyalty, etc.). We kept only the single combination actually active in the source (`crmp_ses_profile1`'s component list).
- **Status polling via `grep`, not a JSON parser.** The Ansible `uri` module parses JSON natively. Our script greps the raw response for `"Status": "Deployed"` to avoid adding a `jq`/`python` dependency — fine for this fixed, known response shape, but worth knowing if Oracle changes the response format in a future Siebel version.

## Idempotency and failure handling

**The script is idempotent — just re-run it.** Each REST step creates something (a registry, a profile, a deployment), and Siebel's API generally rejects a duplicate creation, so the script can't safely resume partway through. Rather than trying to detect and skip already-completed steps, the script sidesteps the problem entirely: its first action is `docker compose up -d --force-recreate mde`, which discards the container's writable filesystem layer (including the gateway registry file, `siebns.dat`) and starts fresh from the built image. Every run begins from the same known-clean state, regardless of whether the previous run partially succeeded, hung, or failed outright.

This matters because most of the state these REST calls create lives *inside the container's own filesystem* (`/siebel/mde/gtwysrvr/sys/siebns.dat` and friends), not in the bind-mounted `/persistent` or `/sfs` volumes — those stay essentially empty until the `initSiebelmde` migration script runs, which this bootstrap flow doesn't invoke. A plain `docker compose restart mde` only restarts the process; it does *not* reset that internal state, which previously caused a second run to hang indefinitely (see below). `--force-recreate` is what actually gets you a clean slate.

**Bounded waits.** Every `curl` call has `--max-time 30`, and `wait_for_deployed` gives up after 360 retries (60 minutes) with a clear error rather than polling forever. Enterprise deployment in a resource-constrained dev environment takes ~30 minutes — the REST API responds quickly throughout (returning "In Progress" until the deployment completes), so a per-call timeout is not the issue; the window just needs to be wide enough to cover the actual deployment duration.

If a step fails:
1. Read the printed response body — the script echoes every API response, so the error detail from Siebel is visible directly
2. Common causes:
   - The database import hasn't finished yet (table owner / schema not ready)
   - The `.env` values don't match what was baked into the image at build time (e.g. `PKI_PWD` or `AI_USER_PWD` changed after the image was built — rebuild the affected image)
   - **`"Profile Validation Failed"` on step 2 (GatewaySecurityProfile):** `AI_USER_PWD` or `SIEBEL_ANON_PWD` doesn't match the live database password for the `sadmin`/`guestcst` Oracle users. As of `01-setup.sh`/`01-setup.sql.template`, these passwords are rendered directly from `.env` at database creation time, so this should only happen if `.env` was changed *after* the database was already created (the SQL setup only runs once). Fix without rebuilding or re-importing by altering the live DB user — see "Key things to know" in the README for the exact command
   - Tomcat wasn't fully up yet when a call fired
3. To retry: just run the script again — the force-recreate at the top handles cleanup

## Verifying success

After the script finishes:
```bash
curl -sk https://localhost/siebel/app/callcenter/enu -o /dev/null -w "%{http_code}\n"
```
A `200` (or a redirect to a login page) confirms the Application Interface is serving Siebel. You can also open `https://localhost/siebel/app/callcenter/enu` directly in a browser — expect a certificate warning since the keystore is self-signed.
