# siebel-docker

Docker Compose setup for a Siebel CRM environment, starting with an Oracle 19c database container pre-loaded with a Siebel schema via Data Pump import.

## Prerequisites

### Oracle Container Registry
Create an account on container-registry.oracle.com and generate a token, then log in:
```bash
docker login -u <username> container-registry.oracle.com
```

### Oracle Instant Client RPMs
Download the following Oracle Instant Client 19.31 **32-bit** RPMs from:
https://www.oracle.com/database/technologies/instant-client/linux-x86-32-downloads.html

- `oracle-instantclient19.31-basic-19.31.0.0.0-1.i386.rpm`
- `oracle-instantclient19.31-sqlplus-19.31.0.0.0-1.i386.rpm`

Place both `.rpm` files in `software/instantclient/` before building images.

### Siebel Enterprise Server installer
Extract the Siebel 24.9 installer zip into `software/Siebel_Enterprise_Server/`. After extraction the directory should contain `Disk1/`.

## Setup

```bash
cp .env.example .env
# edit .env — set ORACLE_PWD, DUMP_FILE, and build args
```

## Building images

Prerequisites:
- Oracle Instant Client RPMs in `software/instantclient/`
- Siebel Enterprise Server installer extracted to `software/Siebel_Enterprise_Server/`
- All required vars set in `.env`

Build in order — each step depends on the previous:

```bash
# 1. Oracle Instant Client base image (prerequisite for CGW, SES, MDE)
docker compose build instantclient

# 2. Siebel Gateway
docker compose build cgw

# 3. Siebel Server
docker compose build ses

# 4. Siebel Application Interface
docker compose build sai

# 5. Siebel MDE (Modular Deployment Engine)
docker compose build mde
```

## Verifying images

After building, run these to confirm each image installed correctly:

```bash
# Check version and response file for each component
docker run --rm ol8/siebel/cgw-base:24.9np cat /siebel/cgw/Siebel_version.properties
docker run --rm ol8/siebel/ses-base:24.9np cat /siebel/ses/Siebel_version.properties
docker run --rm ol8/siebel/sai-base:24.9np cat /siebel/sai/Siebel_version.properties
docker run --rm ol8/siebel/mde-base:24.9np cat /siebel/mde/Siebel_version.properties
```

All should report `SIEBEL_VERSION=24.9.0.0.0`.

## Testing the database connection

With the database container already running, verify the instantclient image can connect:

```bash
docker compose --profile test run --rm test-db
```

A successful connection prints `1` from `SELECT 1 FROM DUAL`. If the connection fails, check that `DB_HOST`, `DB_PORT`, and `DB_SERVICE` in `.env` match the running database container.

## Running the database container

```bash
# Set ownership on the dumps directory so Oracle can write the import log
sudo chown -R 54321:54321 dumps/

# Place your Data Pump export file in ./dumps/
cp /path/to/your/dumpfile.dmp dumps/

docker compose up -d
docker compose logs -f
```

Initial startup takes around 25-30 minutes for Oracle to create the database, then a further 2-3 hours for the Data Pump import to complete.

## What happens on first start

1. Oracle creates the ORCLCDB database
2. `01-setup.sh` runs — renders `01-setup.sql.template` with `AI_USER_PWD`/`SIEBEL_ANON_PWD` from `.env`, then executes it: switches to ORCLPDB1, creates tablespaces, roles, users, and a directory object pointing to `./dumps/`
3. `02-import.sh` runs — imports the SIEBEL schema using `impdp`; import log is written to `dumps/impdp_siebel.log`

Setup scripts only run once. Subsequent container restarts skip them and start the already-provisioned database.

## Verifying the import

Connect to the database and run:
```sql
SELECT app_ver FROM siebel.s_app_ver;
SELECT COUNT(*) FROM siebel.s_contact;
```
Expected: `v24.9` and `30981` respectively.

## Key things to know

- Place your dump file in `./dumps/` and set `DUMP_FILE` in `.env` to match the filename before first start
- The `./dumps/` directory must be writable by the Oracle process (uid 54321) so impdp can write its log file — run `sudo chown -R 54321:54321 dumps/` before starting
- If the first run fails mid-import (e.g. container crash), drop the volume and start clean:
  ```bash
  docker compose down -v
  docker compose up -d
  ```
- The import log at `dumps/impdp_siebel.log` will show errors — some are expected (grants to roles that don't exist in this environment). Verify with the queries above
- `ENABLE_ARCHIVELOG` is hardcoded to `true` as it is required for Siebel
- The `sadmin`/`guestcst` database passwords are rendered from `AI_USER_PWD`/`SIEBEL_ANON_PWD` in `.env` at first startup (`01-setup.sh` renders `01-setup.sql.template`) — there's a single source of truth, so they can't drift out of sync with what the bootstrap script and the SAI/MDE images use
- If you change `AI_USER_PWD` or `SIEBEL_ANON_PWD` *after* the database has already been created, the new value won't retroactively apply — update the live database with `ALTER USER sadmin IDENTIFIED BY "<value>";` (and `guestcst` similarly), or drop the `oracle_data` volume and let it re-provision from scratch

## Running the Siebel containers

Each component's persistent volume must be owned by the `oracle` user (uid/gid 29263, matching the build-time `SIEBEL_UID`/`SIEBEL_GID`) before first start, since the containers write configuration and logs there as that user:

```bash
sudo chown -R 29263:29263 siebel-volumes/
```

Then start all four containers:

```bash
docker compose up -d cgw ses sai mde
docker compose ps
```

The containers start with `/bin/bash` and stay running via an attached tty — none of the Siebel services (gateway, server, AI) start automatically. That happens in the bootstrap step below.

Containers and their network aliases (all on the `siebelnet` network, resolvable by other containers as `<name>.<PKI_DOMAIN>`):

| Service | Container name | Exposed ports |
|---|---|---|
| cgw | `${CGW_HOSTNAME}` | none |
| ses | `${SES_HOSTNAME}` | none |
| sai | `${SAI_HOSTNAME}` | 443 → 6091 |
| mde | `${MDE_HOSTNAME}` | 4443 → 6091, 2322 → 2322 |

## Bootstrapping the Siebel enterprise

With the database imported (see above) and the `mde` container running, bootstrap the Siebel enterprise — this configures the gateway, creates the Enterprise/Server/AI profiles, and deploys them. It's the step that turns "Siebel is installed" into "Siebel is running and reachable in a browser."

Make sure these are set in `.env` first: `SIEBEL_PRIMARY_LANG`, `GW_REGISTRY_PORT`, `SIEBEL_ANON_PWD`.

**Linux / macOS:**
```bash
./scripts/bootstrap-mde.sh
```

**Windows (PowerShell):**
```powershell
.\scripts\bootstrap-mde.ps1
```

This is a re-runnable, idempotent operation — see [docs/bootstrap.md](docs/bootstrap.md) for what it does, timing expectations (~35 min), and troubleshooting.

Once it completes, Siebel is reachable at:
```
https://localhost:4443/siebel/app/<application>/<language>
```
e.g. `https://localhost:4443/siebel/app/publicsector/enu`

Note: port 4443 is MDE's published AI port. Port 443 maps to the SAI container which is built but not bootstrapped in this setup.

## Custom web assets (CSS / JS / images)

The MDE container's Tomcat web root is bind-mounted from `siebel-webroot/` in the project directory:

```
siebel-webroot/     →   /siebel/mde/applicationcontainer_external/siebelwebroot/
  enu/                  Language-specific templates
  files/                Downloadable files
  images/               UI images
  scripts/              JavaScript
  htmltemplates/        HTML page templates
  fonts/                Web fonts
```

To update: edit files in `siebel-webroot/` on the host — changes are served immediately with no container restart needed. `siebel-webroot/` is gitignored since it contains the full Siebel web root (~330MB). To restore it, extract your `siebelwebroot_Backup.zip` into the project root and flatten the top-level directory:

```bash
unzip siebelwebroot_Backup.zip -d siebel-webroot/
mv siebel-webroot/siebelwebroot_Backup/* siebel-webroot/
rmdir siebel-webroot/siebelwebroot_Backup
```
