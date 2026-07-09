# siebel-docker

Single-machine Siebel CRM 24.9 stack running in Docker Compose. One MDE container (Gateway + Server + Application Interface combined) backed by Oracle 19c Enterprise.

For a distributed 4-container setup (separate CGW, SES, SAI), see [docs/distributed.md](docs/distributed.md).

---

## Prerequisites

- Docker Desktop (Mac / Windows) or Docker Engine + Compose plugin v2 (Linux)
- A free account on [container-registry.oracle.com](https://container-registry.oracle.com) to pull the Oracle 19c image

**Windows requirements:**
- Docker Desktop with WSL2 backend enabled
- Git for Windows (includes Git Bash) — [git-scm.com](https://git-scm.com/download/win)
- **Docker Desktop memory: set to 8 GB minimum** (Settings → Resources → Memory). The default (2–4 GB) is not enough — Oracle alone needs ~4 GB and the Siebel Server needs another 4 GB.

All shell scripts run in **Git Bash** on Windows. Open Git Bash from the Start menu (or right-click the project folder → "Git Bash Here") and use the same commands as Linux/macOS.

---

## Getting started

### 1. Clone the repo

```bash
git clone <repo-url> siebel-docker
cd siebel-docker
```

### 2. Log in to Oracle Container Registry

```bash
docker login container-registry.oracle.com
```

Accept the Oracle Database licence in your account at container-registry.oracle.com → Database → enterprise (you only need to do this once).

### 3. Add the Oracle Instant Client RPMs

Download the **32-bit** Oracle Instant Client 19.31 RPMs from Oracle's website:

> Database → Technologies → Instant Client → Linux x86 32-bit

Files needed:
- `oracle-instantclient19.31-basic-19.31.0.0.0-1.i386.rpm`
- `oracle-instantclient19.31-sqlplus-19.31.0.0.0-1.i386.rpm`

Place both files in `software/instantclient/`.

### 4. Add the Siebel Enterprise Server installer

Extract your Siebel 24.9 installer zip into `software/Siebel_Enterprise_Server/`. The directory must contain `Disk1/` after extraction.

### 5. Add the database dump

```bash
cp /path/to/your/export.dmp data/dumps/
```

Set `DUMP_FILE` in `.env` (next step) to match the filename. Ownership on `data/dumps/` is handled automatically by `start.sh` (Linux) — see the note in `start.ps1` for Windows.

### 6. Add the web assets

Extract your `siebelwebroot_Backup.zip` into `data/webroot/`:

**Linux / macOS:**
```bash
unzip siebelwebroot_Backup.zip -d data/webroot/
mv data/webroot/siebelwebroot_Backup/* data/webroot/
rmdir data/webroot/siebelwebroot_Backup
```

**Windows (PowerShell):**
```powershell
Expand-Archive siebelwebroot_Backup.zip -DestinationPath data\webroot\
Move-Item data\webroot\siebelwebroot_Backup\* data\webroot\
Remove-Item data\webroot\siebelwebroot_Backup
```

The `data/webroot/` directory is bind-mounted into the MDE container. Changes on the host are served immediately with no container restart needed.

### 7. Configure .env

```bash
cp .env.example .env
# edit .env
```

**Values you must set:**

| Variable | What it is |
|---|---|
| `ORACLE_PWD` | Password for the Oracle SYS / SYSTEM accounts — set to anything |
| `AI_USER_PWD` | Siebel SADMIN password — **must match the value stored in your DB dump** |
| `SIEBEL_ANON_PWD` | Siebel GUESTCST (anonymous) password — **must match the value in your DB dump** |
| `PKI_PWD` | SSL keystore password — set to anything secure |
| `PKI_DOMAIN` | Your domain, e.g. `company.com` — used in TLS certificate SANs |
| `DUMP_FILE` | Filename of your `.dmp` file as placed in `data/dumps/` |
| `MDE_HOSTNAME` | Hostname for the MDE container, e.g. `dev01mde01` |
| `SIEBEL_ENTERPRISE` | Name for the Siebel enterprise, e.g. `dev01` |

Everything else can stay at its default for a first run. See the [full variable reference](#env-variable-reference) below.

### 8. Run the start script

One script handles the rest: it sets bind-mount ownership, builds the images, starts the database, and runs the bootstrap. Total time from scratch is ~3 hours.

```bash
./scripts/start.sh
```

On Windows, run this in **Git Bash**.

What it does, in order:

1. `sudo chown -R 54321:54321 data/dumps/` — lets Oracle write its import log
2. `sudo chown -R 29263:29263 siebel-volumes/` — lets Siebel containers write configuration and logs
3. Build `instantclient` and `mde` images (~15–30 min, skipped on re-runs if unchanged)
4. Start `oracle19c` — first run: DB creation (~20 min) + schema import (~2 hrs); subsequent runs start the provisioned database immediately
5. Run `bootstrap-mde.sh` — waits for database health, then configures the Siebel enterprise via the Cloud Gateway REST API (~35 min)

The script is idempotent and safe to re-run.

To watch the database logs during the import (in a separate terminal):
```bash
docker compose logs -f oracle19c
```

See [docs/bootstrap.md](docs/bootstrap.md) for what the bootstrap does step by step and how to troubleshoot.

### 9. Open Siebel

Wait 3–5 minutes after the start script finishes for the object managers to initialise, then open:

```
https://localhost:4443/siebel/app/publicsector/enu
```

Login with `SADMIN` / (value of `AI_USER_PWD` in `.env`).

> Port **4443** is MDE's Application Interface. Port 443 is reserved for the standalone SAI container used in the [distributed setup](docs/distributed.md).

---

## .env variable reference

| Variable | Default | Description |
|---|---|---|
| `ORACLE_PWD` | — | Oracle SYS / SYSTEM password |
| `DUMP_FILE` | — | Data Pump export filename (file must be in `data/dumps/`) |
| `OL_VERSION` | `8` | Oracle Linux major version used as base for images |
| `ORACLE_IC_VERSION` | `19.31` | Instant Client version (must match the RPM filenames) |
| `SIEBEL_VERSION` | `24.9` | Siebel version tag applied to built images |
| `DB_HOST` | `db19sbl249` | Container name / hostname for the Oracle container |
| `DB_PORT` | `1521` | Oracle listener port, published to the host |
| `DB_SERVICE` | `ORCLPDB1` | Oracle PDB service name |
| `PKI_PWD` | — | Password for the SSL keystores baked into Siebel images |
| `PKI_DOMAIN` | `company.com` | Domain used in TLS certificate SANs |
| `GW_HTTP_PORT` | `4091` | Gateway Tomcat HTTP port (internal) |
| `GW_SHUTDOWN_PORT` | `4092` | Gateway Tomcat shutdown port (internal) |
| `GW_REDIRECT_PORT` | `4090` | Gateway Tomcat HTTPS redirect port (internal) |
| `SES_HTTP_PORT` | `5090` | Server Tomcat HTTP port (internal) |
| `SES_SHUTDOWN_PORT` | `5092` | Server Tomcat shutdown port (internal) |
| `SES_REDIRECT_PORT` | `5091` | Server Tomcat HTTPS redirect port (internal) |
| `AI_HTTP_PORT` | `6090` | Application Interface HTTP port (internal) |
| `AI_SHUTDOWN_PORT` | `6092` | Application Interface shutdown port (internal) |
| `AI_REDIRECT_PORT` | `6091` | Application Interface HTTPS port — published as **4443** on the host |
| `AI_USERNAME` | `SADMIN` | Siebel administrator Oracle DB username |
| `AI_USER_PWD` | — | Siebel administrator password |
| `SIEBEL_ENTERPRISE` | `dev01` | Siebel enterprise name |
| `MDE_HOSTNAME` | `dev01mde01` | MDE container hostname |
| `GW_TLS_PORT` | `2320` | Gateway TLS port |
| `SIEBEL_UID` | `29263` | UID of the `oracle` OS user inside Siebel containers |
| `SIEBEL_GID` | `29263` | GID of the `oracle` OS group inside Siebel containers |
| `SIEBEL_PRIMARY_LANG` | `enu` | Primary language code for the enterprise |
| `GW_REGISTRY_PORT` | `2322` | Zookeeper registry port — published from the MDE container |
| `SIEBEL_ANON_PWD` | — | Anonymous / guest login password (username is `GUESTCST`) |
| `CGW_HOSTNAME` | `dev01cgw01` | CGW container hostname — distributed setup only |
| `SES_HOSTNAME` | `dev01ses01` | SES container hostname — distributed setup only |
| `SAI_HOSTNAME` | `dev01sai01` | SAI container hostname — distributed setup only |

---

## Verifying the schema import

After the database is ready, connect and run:

```sql
SELECT app_ver FROM siebel.s_app_ver;
SELECT COUNT(*) FROM siebel.s_contact;
```

Expected: `v24.9` and `30981` respectively.

## Verifying the built images

After the build completes, confirm Siebel installed correctly:

```bash
docker run --rm ol8/siebel/mde-base:24.9np cat /siebel/mde/Siebel_version.properties
```

Expected: `SIEBEL_VERSION=24.9.0.0.0`.

---

## Stopping and restarting

To stop all containers (data is preserved):

```bash
docker compose stop
```

To start them again without rebuilding or re-bootstrapping:

```bash
./scripts/restart.sh
```

This starts the containers, waits for Oracle, starts the Siebel Tomcats, and tells you when the UI is ready.

> **Never** run `docker compose down -v` — the `-v` flag destroys the Oracle data volume and requires a full 2-hour schema re-import.

---

## Key operational notes

- **Changing passwords after first start**: `AI_USER_PWD` and `SIEBEL_ANON_PWD` are rendered into the Oracle DB on first start by `01-setup.sh`. If you change them in `.env` afterwards, update the live DB with `ALTER USER sadmin IDENTIFIED BY "...";` (and `guestcst` similarly), or drop the `oracle_data` volume and let the DB re-provision from scratch with `docker compose down -v`.
- **Failed import**: If the container crashes mid-import, drop the volume and start clean: `docker compose down -v && docker compose up -d oracle19c`.
- **Import log**: `data/dumps/impdp_siebel.log`. Some grant errors are expected (roles that don't exist in this environment). Verify with the SQL queries above.
- **Re-bootstrapping**: The bootstrap script force-recreates the MDE container every run, wiping its internal gateway state. Running it again does a full reconfiguration from scratch.
- **`ENABLE_ARCHIVELOG`** is hardcoded to `true` — required by Siebel.

---

## Distributed (4-container) setup

See [docs/distributed.md](docs/distributed.md) for the architecture using separate CGW, SES, and SAI containers. That setup uses `docker-compose.distributed.yml`.
