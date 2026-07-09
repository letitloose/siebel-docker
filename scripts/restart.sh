#!/bin/bash
# Restart already-provisioned containers without rebuilding or re-bootstrapping.
# Use this after docker compose stop or a machine reboot.
# Never use docker compose down -v — that destroys the Oracle data volume.
export MSYS_NO_PATHCONV=1
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
source .env
set +a

MDE_URL="https://localhost:4443/siebel/v1.0"
CURL_MAX_TIME=120

echo "==> Starting containers"
docker compose start

echo "==> Waiting for Oracle to be ready"
until docker compose exec -T oracle19c bash -c \
    "echo 'SELECT count(*) FROM siebel.s_app_ver;' | sqlplus -s sys/${ORACLE_PWD}@//localhost:1521/ORCLPDB1 as sysdba" \
    2>/dev/null | grep -qE '^[[:space:]]*[1-9][0-9]*[[:space:]]*$'; do
    echo "    [$(date '+%H:%M:%S')] Waiting for database..."
    sleep 10
done
echo "    [$(date '+%H:%M:%S')] Database ready."

echo "==> Starting MDE internal and external Tomcat"
docker compose exec -T --workdir /config mde bash ./start_ai_internal.sh
docker compose exec -T --workdir /config mde bash ./start_ai_external.sh

echo "==> Waiting for the Cloud Gateway REST API to respond"
until curl -sk --max-time "$CURL_MAX_TIME" "${MDE_URL}/cginfo" > /dev/null; do
    sleep 5
done

echo "==> Siebel is up. Wait 3-5 minutes for object managers to initialise, then open:"
echo "    https://localhost:4443/siebel/app/publicsector/${SIEBEL_PRIMARY_LANG}"
echo "    Login: ${AI_USERNAME} / (value of AI_USER_PWD in .env)"
