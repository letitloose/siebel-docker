#!/bin/bash
export MSYS_NO_PATHCONV=1
# Full setup: chown bind mounts, build images, start the database, and bootstrap Siebel.
# Safe to re-run — all steps are idempotent.
#
# First run takes ~3 hours (DB creation ~20 min + schema import ~2 hrs + bootstrap ~35 min).
#
#   ./scripts/start.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source .env; set +a

echo "==> Setting ownership on ${DATA_DIR:-./data}/dumps/ (Oracle process runs as uid 54321)"
sudo chown -R 54321:54321 "${DATA_DIR:-./data}/dumps/"

echo "==> Preparing Oracle data directory ${ORACLE_DATA_DIR:-./oracle-data}"
mkdir -p "${ORACLE_DATA_DIR:-./oracle-data}"
sudo chown -R 54321:54321 "${ORACLE_DATA_DIR:-./oracle-data}"

echo "==> Setting ownership on siebel-volumes/ (Siebel containers run as uid ${SIEBEL_UID})"
sudo chown -R "${SIEBEL_UID}:${SIEBEL_GID}" siebel-volumes/

echo "==> 1/2  Building Oracle Instant Client base image"
docker compose build instantclient

echo "==> 2/2  Building Siebel MDE (all-in-one Gateway + Server + AI)"
docker compose build mde

echo "==> Starting Oracle database"
echo "    First run: DB creation (~20 min) + schema import (~2 hrs)"
echo "    Subsequent runs: starts the already-provisioned database in seconds"
docker compose up -d oracle19c

echo "==> Bootstrapping Siebel (waits for database health, then configures the enterprise)"
./scripts/bootstrap-mde.sh
