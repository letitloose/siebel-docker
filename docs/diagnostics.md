# Siebel stack diagnostics

Run `./scripts/diagnose.sh` for a one-shot health check. This document explains what
each check does and why, so you can dig deeper when the script surfaces a problem.

---

## 1. Container states

```bash
docker compose ps
```

**Purpose:** Confirm both containers (`oracle19c`, `mde`) are actually running. If a
container has exited, nothing else will work and the error messages from later checks
will be misleading. The `oracle19c` health status (`starting` → `healthy`) also tells
you whether the Oracle listener is up — though `healthy` only means the listener is
accepting connections, not that the Siebel schema has finished importing.

**What to look for:**
- Both containers in `running` state.
- `oracle19c` health: `starting` is normal for the first ~20 minutes. If it stays
  `starting` for more than an hour something went wrong with DB creation.

---

## 2. Database schema readiness

```bash
docker compose exec -T oracle19c bash -c \
  "echo 'SELECT count(*) FROM siebel.s_app_ver;' | timeout 15 sqlplus -s \
   sys/<ORACLE_PWD>@//localhost:1521/ORCLPDB1 as sysdba"
```

**Purpose:** The Oracle container health check only probes the listener, not the Siebel
schema. The actual Siebel schema import (`impdp`) runs as a post-init script and takes
~2 hours on first boot. Querying `siebel.s_app_ver` — a core Siebel metadata table —
is the definitive signal that the import has completed and the schema is ready.

If the bootstrap started before this returned a row count, step 2
(GatewaySecurityProfile) will fail with "Profile Validation Failed" because the Gateway
tries to authenticate against the DB and finds no users.

**What to look for:**
- A row count ≥ 1 means the schema is ready.
- `ORA-00942: table or view does not exist` means the import hasn't finished yet.
- `ORA-12514: TNS listener does not currently know of service` means the PDB isn't open
  yet (Oracle still starting up or running init scripts).

---

## 3. Cloud Gateway API connectivity

```bash
# Step A — unauthenticated probe
curl -sk -o /dev/null -w "%{http_code}" https://localhost:4443/siebel/v1.0/cginfo

# Step B — authenticated request
curl -sk --user "SADMIN:<password>" https://localhost:4443/siebel/v1.0/cginfo
```

**Purpose:** The Cloud Gateway management API is the control plane for everything in
steps 1–9 of the bootstrap. If it isn't responding, the bootstrap can't configure
anything.

Step A just tests network reachability and whether the Tomcat/SAI is up. Step B tests
that the Gateway itself started and your credentials work.

**What to look for:**
- `000` (curl code) → Tomcat not listening. Internal Tomcat hasn't started yet (run
  `start_ai_internal.sh` from the bootstrap) or MDE container is stopped.
- `401` → Tomcat is up, Gateway is running, but you need valid credentials. Expected
  for the unauthenticated probe.
- `200` with `{"CGHostURI": ...}` → Gateway is up and auth works. Good.
- Empty body with `200` → Tomcat is up but the Siebel WAR hasn't deployed yet.

---

## 4. Deployment statuses

```bash
curl -sk --user "SADMIN:<pwd>" \
  https://localhost:4443/siebel/v1.0/cloudgateway/deployments/enterprises/<ENTERPRISE>

curl -sk --user "SADMIN:<pwd>" \
  https://localhost:4443/siebel/v1.0/cloudgateway/deployments/servers/siebses1

curl -sk --user "SADMIN:<pwd>" \
  https://localhost:4443/siebel/v1.0/cloudgateway/deployments/swsm/siebsai1
```

**Purpose:** The bootstrap script runs nine REST API calls against the Gateway. These
three queries tell you whether the Gateway has recorded a completed deployment for the
Enterprise, the Siebel Server, and the Application Interface (SAI). A `ConfigNodeNotExists`
error on all three means the bootstrap never finished past step 3 (often caused by a
`bootstrapCG` timeout or the host going to sleep mid-run).

**What to look for:**
- `"Status": "Deployed"` on all three → bootstrap completed successfully.
- `"Status": "DeployInProgress"` → a deployment is still running (or stalled).
- `ConfigNodeNotExists` → that deployment never happened. Re-run `bootstrap-mde.sh`.

---

## 5. Siebel processes in MDE container

```bash
docker compose exec -T mde bash -c \
  "ps aux | grep -E '(siebsrvr|gtwyns|zookeeper|applicationcontainer)' | grep -v grep"
```

**Purpose:** Deployment status in the Gateway is configuration state — it doesn't
guarantee the actual OS processes are running. This check bypasses the Siebel layer
entirely and looks directly at what's alive inside the container.

The key processes and what they do:

| Process pattern | What it is |
|---|---|
| `gtwyns` | Gateway Name Server — manages the Siebel namespace and routes to Zookeeper |
| `zookeeper` / `QuorumPeerMain` | Zookeeper registry — stores all Gateway config (replaces the old .dat file) |
| `siebsvc -s siebsrvr` | Siebel Server main process — parent for all component processes |
| `applicationcontainer_internal` | Internal Tomcat — hosts the Cloud Gateway REST API (port 5091 internally) |
| `applicationcontainer_external` | External Tomcat — the SAI/AI, serves the Siebel UI (port 6091 internally → 4443 on host) |
| `siebmtshmw` | MT Object Manager worker threads — one per active OM task |
| `SCBroker` (via siebsvc) | Connection Broker — routes browser sessions to available OM tasks |

**What to look for:**
- All five process groups present → Siebel stack is fully started.
- Missing `siebsrvr` → Siebel Server didn't start. Check `SiebSrvr.log`.
- Missing `applicationcontainer_external` → External Tomcat not started. Run
  `start_ai_external.sh` from `/config` inside the MDE container.
- Missing `zookeeper` → Gateway registry didn't start. The Gateway can't store or
  serve configuration.

---

## 6. Siebel component status (srvrmgr)

```bash
docker compose exec -T mde bash -c \
  "source /siebel/mde/siebsrvr/siebenv.sh && \
   echo 'list components' | \
   srvrmgr /g dev01mde01:2320 /e dev01 /s siebses1 /u SADMIN /p '<password>'"
```

**Purpose:** `srvrmgr` is the Siebel Server Manager CLI. It connects directly to the
Siebel Server process and reports the runtime state of every configured component. This
is the most important diagnostic step — it tells you whether the Object Managers (OMs)
that handle browser sessions are actually ready.

`siebenv.sh` must be sourced first because `srvrmgr` depends on library paths
(`LD_LIBRARY_PATH`) that aren't in the container's default environment.

**Component states and what they mean:**

| State | Meaning |
|---|---|
| `Running` | Component is active and processing tasks (e.g. SCBroker handling connections) |
| `Online` | Component is idle — ready to accept requests but no active tasks yet |
| `Not Online` | Component is enabled but not yet started — still initializing, or blocked on a dependency |
| `Unavailable` | Component tried to start and failed — check the component's own log file |
| `Offline` | Component has been manually disabled |

**What to look for:**
- `SCBroker` must be `Running`. It is the connection broker — if it's not running,
  no browser sessions can reach any Object Manager.
- The Object Managers wired to your application URLs must be `Online` (or `Running`):
  - `PSCcObjMgr_enu` → `/siebel/app/publicsector/enu`
  - `SCCObjMgr_enu`  → `/siebel/app/callcenter/enu`
  - `EAIObjMgr_enu`  → `/siebel/app/eai/enu`
- `Not Online` on an OM right after server startup is **normal** — these OMs are
  heavy and take 15–20 minutes to initialize on first boot. Wait and re-check.
- `Not Online` on an OM after 30+ minutes suggests a startup error. Look in
  `/siebel/mde/siebsrvr/log/` for a log file named after the OM alias.
- High `Not Online` count across many components can also mean the Siebel Server
  is still in its first-boot initialization pass — give it more time.

---

## 7. SiebSrvr.log errors

```bash
docker compose exec -T mde bash -c \
  "grep 'SBL-' /siebel/mde/siebsrvr/log/SiebSrvr.log | \
   grep -v 'SBL-SCC-00025\|SBL-SCC-00018' | \
   grep -o 'SBL-[A-Z]*-[0-9]*.*' | sort -u | tail -10"
```

**Purpose:** `SiebSrvr.log` is the main Siebel Server log. It's very noisy — hundreds
of `SBL-SCC-00025` ("No value found in Gateway, using repository default") lines appear
at every startup and are harmless (the server uses the compiled-in default for any
parameter not stored in Zookeeper). Filtering those out surfaces the real errors.

**What to look for:**
- `SBL-NET-*` → network/TLS errors. Common on first boot as the server discovers its
  own TLS config. Persistent ones may indicate a certificate or port mismatch.
- `SBL-SCM-00028: Key not found` → similar to SCC-00025, benign during startup.
- `SBL-OPR-*` → operational errors. Usually indicate a component failed to start.
- `SBL-DAT-*` → database errors. May mean the DB connection is broken.
