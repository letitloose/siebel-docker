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
2. `01-setup.sql` runs — switches to ORCLPDB1, creates tablespaces, roles, users, and a directory object pointing to `./dumps/`
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
