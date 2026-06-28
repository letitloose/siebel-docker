# Oracle Instant Client Image

**Image tag:** `ol8/instantclient/32bit:19.31`
**Dockerfile:** `docker/instantclient/Dockerfile`
**Base:** `oraclelinux:8-slim`

This is the foundation image for CGW, SES, and MDE. It provides the 32-bit Oracle Instant Client libraries that Siebel requires for database connectivity, and generates a `tnsnames.ora` pointing at the database container.

## Build args

| ARG | Default | Purpose |
|---|---|---|
| `OL_VERSION` | `8` | Oracle Linux version for the base image |
| `ORACLE_IC_VERSION` | `19.31` | Instant Client version — must match the RPM filenames |
| `DB_HOST` | _(required)_ | Database container hostname (e.g. `db19sbl249`) |
| `DB_PORT` | _(required)_ | Database listener port (e.g. `1521`) |
| `DB_SERVICE` | _(required)_ | Oracle service name (e.g. `ORCLPDB1`) |

## Dockerfile steps

**1. Base image**
Starts from `oraclelinux:8-slim`, a minimal Oracle Linux image with only `microdnf` available.

**2. COPY RPMs**
Copies all `*.rpm` files from `software/instantclient/` into the root of the container. The wildcard picks up both the `basic` and `sqlplus` RPMs automatically.

**3. RUN — package install and tnsnames.ora generation**
All steps are in a single `RUN` to keep the layer count low:

- Installs `ksh`, `tcsh`, `glibc.i686`, `libaio.i686` via `microdnf` (prerequisites for `dnf`)
- Installs `dnf` via `microdnf` to gain the full package manager
- Installs the Instant Client RPMs via `dnf` — the version wildcard `oracle-instantclient${ORACLE_IC_VERSION}*.i386.rpm` matches all downloaded RPMs
- Cleans package caches and removes the RPM files to reduce image size
- Generates `/config/tnsnames.ora` using `printf` with the `DB_HOST`, `DB_PORT`, and `DB_SERVICE` build args — no static template file needed

**4. ENV**
Sets:
- `ORACLE_HOME` — Instant Client home directory
- `TNS_ADMIN` — points to `/config/` so Oracle tools find `tnsnames.ora`
- `LD_LIBRARY_PATH` — includes the 32-bit client library path
- `PATH` — includes the Instant Client bin directory (provides `sqlplus`)
- `LANG=en_US.UTF-8` — required for Siebel character encoding

## Prerequisites

Place these files in `software/instantclient/` before building:
- `oracle-instantclient19.31-basic-19.31.0.0.0-1.i386.rpm`
- `oracle-instantclient19.31-sqlplus-19.31.0.0.0-1.i386.rpm`
