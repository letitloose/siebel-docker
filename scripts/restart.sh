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
docker compose start oracle19c mde

echo "==> Waiting for Oracle to be ready"
until docker compose exec -T oracle19c bash -c \
    "echo 'SELECT count(*) FROM siebel.s_app_ver;' | sqlplus -s sys/${ORACLE_PWD}@//localhost:1521/ORCLPDB1 as sysdba" \
    2>/dev/null | grep -qE '^[[:space:]]*[1-9][0-9]*[[:space:]]*$'; do
    echo "    [$(date '+%H:%M:%S')] Waiting for database..."
    sleep 10
done
echo "    [$(date '+%H:%M:%S')] Database ready."

CG_LOG=/siebel/mde/applicationcontainer_internal/logs/catalina.out
CG_MARKER="RESTART_CG_START_$(date +%s)"
docker compose exec -T mde bash -c "mkdir -p \$(dirname $CG_LOG) && echo '$CG_MARKER' > $CG_LOG"

echo "==> Starting internal Tomcat (Cloud Gateway)"
docker compose exec -T --workdir /config mde bash ./start_ai_internal.sh

echo "==> Waiting for Cloud Gateway to be ready (takes ~6 min on first start)"
until docker compose exec -T mde bash -c \
    "grep -A99999 '$CG_MARKER' $CG_LOG 2>/dev/null | grep -q 'Server startup in'"; do
    echo "    [$(date '+%H:%M:%S')] Waiting for Cloud Gateway..."
    sleep 15
done
echo "    [$(date '+%H:%M:%S')] Cloud Gateway ready."

echo "==> Starting external Tomcat (Application Interface)"
docker compose exec -T --workdir /config mde bash ./start_ai_external.sh

echo "==> Waiting for Application Interface port to open"
until [ "$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "${MDE_URL}/cginfo")" != "000" ]; do
    echo "    [$(date '+%H:%M:%S')] Waiting for Application Interface..."
    sleep 5
done
echo "    [$(date '+%H:%M:%S')] Application Interface ready."

echo "==> Warming Oracle buffer cache in background (5-15 min)"
./scripts/warmup-db.sh &

echo "==> Waiting for Object Managers to initialise (3-5 min)"
until curl -sk --max-time 300 \
    -X POST "${MDE_URL}/auth" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${AI_USERNAME}\",\"password\":\"${AI_USER_PWD}\"}" \
    | grep -q '"token"'; do
    sleep 15
done
echo "    Object managers ready."

echo "==> Triggering Web Tools Object Manager initialisation in background (10-20 min)"
curl -sk --max-time 1200 \
    "https://localhost:4443/siebel/app/webtools/${SIEBEL_PRIMARY_LANG}" \
    > /dev/null 2>&1 &
echo "    Web Tools will be warm by the time you need it."

echo "==> Siebel is up:"
echo "    https://localhost:4443/siebel/app/publicsector/${SIEBEL_PRIMARY_LANG}"
echo "    Login: ${AI_USERNAME} / (value of AI_USER_PWD in .env)"
