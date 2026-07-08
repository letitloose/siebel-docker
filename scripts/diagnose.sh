#!/bin/bash
# Diagnoses the health of the Siebel Docker stack.
# See docs/diagnostics.md for an explanation of each check.
#
# Usage: ./scripts/diagnose.sh

set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

# ── Output helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
BOLD='\033[1m'; NC='\033[0m'
ok()      { echo -e "  ${GREEN}✓${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*"; WARNINGS=$((WARNINGS+1)); }
fail()    { echo -e "  ${RED}✗${NC}  $*"; ISSUES=$((ISSUES+1)); }
section() { echo -e "\n${BOLD}==> $*${NC}"; }

ISSUES=0; WARNINGS=0
MDE_URL="https://localhost:4443/siebel/v1.0"
CURL="curl -sk --max-time 15"

# ── 1. Container states ────────────────────────────────────────────────────────
section "1. Container states"

for svc in oracle19c mde; do
    state=$(docker inspect --format '{{.State.Status}}' \
        "$(docker compose ps -q "$svc" 2>/dev/null)" 2>/dev/null || echo "missing")
    health=$(docker inspect --format '{{.State.Health.Status}}' \
        "$(docker compose ps -q "$svc" 2>/dev/null)" 2>/dev/null || echo "")

    if [ "$state" = "running" ]; then
        [ -n "$health" ] && ok "$svc — running (health: $health)" || ok "$svc — running"
    else
        fail "$svc — $state (expected: running)"
    fi
done

# ── 2. Database schema ─────────────────────────────────────────────────────────
section "2. Database schema"

schema_output=$(docker compose exec -T oracle19c bash -c \
    "printf 'SET PAGESIZE 0 FEEDBACK OFF HEADING OFF\nSELECT count(*) FROM siebel.s_app_ver;\nEXIT;\n' | \
     timeout 15 sqlplus -s sys/${ORACLE_PWD}@//localhost:1521/ORCLPDB1 as sysdba" \
    2>/dev/null || true)

schema_count=$(echo "$schema_output" | grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' | tr -d '[:space:]' | head -1 || true)

if echo "$schema_count" | grep -qE '^[1-9][0-9]*$'; then
    ok "Siebel schema present — s_app_ver has ${schema_count} row(s)"
elif echo "$schema_output" | grep -q "ORA-12514"; then
    fail "DB not ready — ORCLPDB1 listener not yet available (Oracle still starting)"
elif echo "$schema_output" | grep -q "ORA-00942"; then
    fail "Siebel schema not imported — s_app_ver table does not exist yet"
else
    fail "Schema check inconclusive — output: $(echo "$schema_output" | head -2 | tr '\n' ' ')"
fi

# ── 3. Cloud Gateway API ───────────────────────────────────────────────────────
section "3. Cloud Gateway API"

http_code=$($CURL -o /dev/null -w "%{http_code}" "${MDE_URL}/cginfo" 2>/dev/null || echo "000")

case "$http_code" in
    000) fail "Gateway not reachable — connection refused or timeout (Tomcat not up?)" ;;
    401) ok "Gateway reachable — auth required (expected)" ;;
    200) warn "Gateway reachable — responded 200 without credentials (check auth config)" ;;
    *)   warn "Gateway returned unexpected HTTP $http_code" ;;
esac

if [ "$http_code" != "000" ]; then
    gw_resp=$($CURL --user "${AI_USERNAME}:${AI_USER_PWD}" "${MDE_URL}/cginfo" 2>/dev/null || true)
    if echo "$gw_resp" | grep -q "CGHostURI"; then
        cghost=$(echo "$gw_resp" | grep -o '"CGHostURI":"[^"]*"' | head -1)
        ok "Authenticated — $cghost"
    else
        fail "Auth failed or unexpected response: $(echo "$gw_resp" | head -c 120)"
    fi
fi

# ── 4. Bootstrap deployment statuses ──────────────────────────────────────────
section "4. Deployment statuses"

check_deployment() {
    local label=$1 path=$2
    local resp status
    resp=$($CURL --user "${AI_USERNAME}:${AI_USER_PWD}" "${MDE_URL}${path}" 2>/dev/null || true)
    status=$(echo "$resp" | grep -o '"Status" *: *"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"')
    case "$status" in
        Deployed)        ok "$label: Deployed" ;;
        DeployInProgress) warn "$label: DeployInProgress — still deploying, check back in a few minutes" ;;
        "")              fail "$label: not found — bootstrap may not have completed (re-run bootstrap-mde.sh)" ;;
        *)               warn "$label: $status" ;;
    esac
}

check_deployment "Enterprise (${SIEBEL_ENTERPRISE})" "/cloudgateway/deployments/enterprises/${SIEBEL_ENTERPRISE}"
check_deployment "Siebel Server (siebses1)"           "/cloudgateway/deployments/servers/siebses1"
check_deployment "App Interface (siebsai1)"           "/cloudgateway/deployments/swsm/siebsai1"

# ── 5. Key OS processes in MDE container ──────────────────────────────────────
section "5. Siebel processes (MDE container)"

check_proc() {
    local label=$1 pattern=$2
    if docker compose exec -T mde bash -c "pgrep -f '$pattern' > /dev/null 2>&1"; then
        ok "$label"
    else
        fail "$label — process not found"
    fi
}

check_proc "Zookeeper registry"         "QuorumPeerMain"
check_proc "Gateway Name Server"        "gtwyns"
check_proc "Siebel Server (siebsrvr)"   "siebsvc.*siebsrvr"
check_proc "Internal Tomcat (CGW API)"  "applicationcontainer_internal"
check_proc "External Tomcat (SAI/UI)"   "applicationcontainer_external"

# ── 6. Siebel component status via srvrmgr ────────────────────────────────────
section "6. Siebel component status (srvrmgr)"

# Key OMs mapped to application URLs in the AI profile (bootstrap step 6).
# If these are Not Online, the corresponding application URL returns "server busy".
declare -A APP_OMS=(
    [PSCcObjMgr_enu]="publicsector"
    [SCCObjMgr_enu]="callcenter"
    [EAIObjMgr_enu]="eai"
)

COMP_OUTPUT=$(docker compose exec -T \
    -e SIEBELPASS="${AI_USER_PWD}" \
    mde bash -c \
    'source /siebel/mde/siebsrvr/siebenv.sh 2>/dev/null
     printf "list components\n" | \
     timeout 30 srvrmgr \
         /g dev01mde01:2320 /e dev01 /s siebses1 \
         /u SADMIN /p "$SIEBELPASS" 2>&1' \
    2>/dev/null || true)

if ! echo "$COMP_OUTPUT" | grep -q "Connected to"; then
    fail "srvrmgr could not connect — Siebel Server may still be starting up"
    echo "    $(echo "$COMP_OUTPUT" | grep -v '^$' | tail -3 | sed 's/^/    /')"
else
    running=$(echo "$COMP_OUTPUT" | grep -c "Running"    || true)
    online=$(echo  "$COMP_OUTPUT" | grep -c " Online "   || true)
    noton=$(echo   "$COMP_OUTPUT" | grep -c "Not Online" || true)
    unavail=$(echo "$COMP_OUTPUT" | grep -c "Unavailable" || true)

    ok "srvrmgr connected — Running: ${running}  Online: ${online}  Not Online: ${noton}  Unavailable: ${unavail}"

    echo ""
    echo "  Application Object Managers:"
    for comp in "${!APP_OMS[@]}"; do
        app="${APP_OMS[$comp]}"
        url="https://localhost:4443/siebel/app/${app}/enu"
        line=$(echo "$COMP_OUTPUT" | grep -i "^siebses1  *${comp} " | head -1)
        status=$(echo "$line" | grep -oE 'Running|Not Online|Online|Unavailable' | head -1)
        case "$status" in
            Running|Online)
                ok "$comp → $url"
                ;;
            "Not Online")
                warn "$comp → $url  [Not Online — OM still initializing; wait 15–20 min after server start]"
                ;;
            Unavailable)
                fail "$comp → $url  [Unavailable — startup error; check /siebel/mde/siebsrvr/log/]"
                ;;
            *)
                warn "$comp → $url  [status unknown: '${status}']"
                ;;
        esac
    done

    if [ "$noton" -gt 0 ] || [ "$unavail" -gt 0 ]; then
        echo ""
        echo "  All non-Online components:"
        echo "$COMP_OUTPUT" \
            | grep -E "Not Online|Unavailable" \
            | awk '{printf "    %-30s %s\n", $2, $(NF-3)}' \
            | head -20
    fi
fi

# ── 7. Recent errors in SiebSrvr.log ─────────────────────────────────────────
section "7. SiebSrvr.log — notable errors (noise filtered)"

# SBL-SCC-00025 / 00018 are benign "no value in Gateway, using default" messages
# that flood the log at every startup. Filter them to surface real issues.
errors=$(docker compose exec -T mde bash -c \
    "grep -h 'SBL-' /siebel/mde/siebsrvr/log/SiebSrvr.log 2>/dev/null \
     | grep -v 'SBL-SCC-00025\|SBL-SCC-00018\|SBL-SCM-00028\|SBL-NET-01568' \
     | grep -o 'SBL-[A-Z]*-[0-9]*[^$]*' \
     | sort -u | tail -10" 2>/dev/null || true)

if [ -z "$errors" ]; then
    ok "No notable errors in SiebSrvr.log"
else
    echo "$errors" | while IFS= read -r line; do
        warn "$line"
    done
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}────────────────────────────────────────${NC}"
if [ "$ISSUES" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All checks passed.${NC}"
    echo "Siebel UI: https://localhost:4443/siebel/app/publicsector/enu"
elif [ "$ISSUES" -eq 0 ]; then
    echo -e "${YELLOW}${BOLD}${WARNINGS} warning(s) — stack may still be initializing.${NC}"
else
    echo -e "${RED}${BOLD}${ISSUES} failure(s), ${WARNINGS} warning(s).${NC}"
    echo "See docs/diagnostics.md for guidance on each check."
fi
