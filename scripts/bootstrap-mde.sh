#!/bin/bash
# Bootstraps the Siebel Enterprise inside the MDE container by replicating
# the REST API calls the original Ansible playbook (0004) made against the
# Siebel Cloud Gateway management API. See docs/bootstrap.md for the full
# explanation of what each step does and why.
#
# Idempotent: the script force-recreates the mde container itself before
# doing anything else, so it always starts from the same clean
# just-built state regardless of whether a previous run partially
# succeeded, hung, or failed. Run after the database import has completed.

set -euo pipefail

cd "$(dirname "$0")/.."
set -a
source .env
set +a

MDE_URL="https://localhost:4443/siebel/v1.0"
AUTH="${AI_USERNAME}:${AI_USER_PWD}"
CURL_MAX_TIME=30

# These map to database users created by 01-setup.sql.template. Their
# passwords are configurable (AI_USER_PWD/SIEBEL_ANON_PWD in .env, also
# used to render that SQL template), but the usernames themselves are
# fixed Siebel conventions with no independent configurability — changing
# them here wouldn't rename the corresponding DB user, so they're kept
# as constants rather than .env variables.
SIEBEL_TABLEOWNER=SIEBEL
SIEBEL_ANON_USER=GUESTCST
# Expected number of '. . imported' lines in the impdp log for Siebel 24.9.
# Update if you switch to a different dump version.
IMPORT_OBJECT_TOTAL=5665

# Performs a curl request against the Cloud Gateway API and prints the
# response. -k is required because the server uses the self-signed
# certificate generated at image build time. --max-time bounds how long
# a single call can hang, so a stuck request fails loudly instead of
# blocking the script forever.
api() {
    local method=$1
    local path=$2
    local body=${3:-}

    if [ -n "$body" ]; then
        curl -sk --max-time "$CURL_MAX_TIME" -X "$method" "${MDE_URL}${path}" \
            --user "$AUTH" \
            -H "Content-Type: application/json" \
            -d "$body"
    else
        curl -sk --max-time "$CURL_MAX_TIME" -X "$method" "${MDE_URL}${path}" --user "$AUTH"
    fi
    echo
}

# Polls a deployment status endpoint until it reports "Deployed", giving
# up after max_retries attempts rather than looping forever.
# Each check polls every 10 seconds. With 360 retries that is a 60-minute
# window — enterprise deployment in a dev environment has been observed to
# take ~30 minutes.
wait_for_deployed() {
    local path=$1
    local max_retries=360
    local attempt=0
    echo "Waiting for ${path} to report Deployed..."
    while true; do
        local response
        response=$(curl -sk --max-time 30 "${MDE_URL}${path}" --user "$AUTH")
        local curl_exit=$?
        local ts
        ts=$(date '+%H:%M:%S')
        echo "[${ts}] attempt=${attempt} curl_exit=${curl_exit} response=${response}"
        if echo "$response" | grep -q '"Status"[[:space:]]*:[[:space:]]*"Deployed"'; then
            echo "[${ts}] Matched Deployed — proceeding"
            break
        fi
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_retries" ]; then
            echo "ERROR: ${path} did not report Deployed after $((max_retries * 10))s. Aborting." >&2
            exit 1
        fi
        sleep 10
    done
}

echo "==> Recreating the mde container for a guaranteed clean starting state"
docker compose up -d --force-recreate mde
echo "==> Waiting for Siebel schema to be ready"
echo "    On first run this takes ~2 hours (DB creation + schema import). Polling every 5 minutes..."
until docker compose exec -T oracle19c bash -c \
    "echo 'SELECT count(*) FROM siebel.s_app_ver;' | timeout 30 sqlplus -s sys/${ORACLE_PWD}@//localhost:1521/ORCLPDB1 as sysdba" \
    2>/dev/null | grep -qE '^[[:space:]]*[1-9][0-9]*[[:space:]]*$'; do
    imported=$(docker compose exec -T oracle19c grep -c '. . imported' /opt/oracle/dumps/impdp_siebel.log 2>/dev/null || echo 0)
    last_obj=$(docker compose logs oracle19c 2>/dev/null \
        | grep "Processing object type" | tail -1 \
        | sed 's/.*Processing object type //') || true
    echo "    [$(date '+%H:%M:%S')] ${imported}/${IMPORT_OBJECT_TOTAL} objects imported — phase: ${last_obj:-waiting for import to start}"
    echo "                    Next check in 5 minutes..."
    sleep 300
done
echo "    [$(date '+%H:%M:%S')] Siebel schema ready."

echo "==> Starting MDE internal and external Tomcat"
docker compose exec -T --workdir /config mde bash ./start_ai_internal.sh
docker compose exec -T --workdir /config mde bash ./start_ai_external.sh

echo "==> Waiting for the Cloud Gateway REST API to respond"
until curl -sk --max-time "$CURL_MAX_TIME" -o /dev/null "${MDE_URL}/cginfo"; do
    sleep 5
done

echo "==> 1. Setting Cloud Gateway host info"
api POST /cginfo "{
  \"CGHostURI\": \"${MDE_HOSTNAME}.${PKI_DOMAIN}:${SES_REDIRECT_PORT}\",
  \"CGTlsPort\": \"${GW_TLS_PORT}\"
}"

echo "==> 2. Configuring the Gateway security profile (DB-backed authentication)"
api POST /cloudgateway/GatewaySecurityProfile "{
  \"Profile\": {\"ProfileName\": \"Siebel\"},
  \"SecurityConfigParams\": {
    \"DataSources\": [{
      \"Name\": \"${DB_SERVICE}\",
      \"Type\": \"DB\",
      \"Host\": \"${DB_HOST}\",
      \"Port\": \"${DB_PORT}\",
      \"SqlStyle\": \"Oracle\",
      \"Endpoint\": \"${DB_SERVICE}\",
      \"TableOwner\": \"${SIEBEL_TABLEOWNER}\",
      \"HashUserPwd\": false,
      \"HashAlgorithm\": \"SHA1\",
      \"CRC\": \"\"
    }],
    \"SecAdptName\": \"DBSecAdpt\",
    \"SecAdptMode\": \"DB\",
    \"NSAdminRole\": [\"Siebel Administrator\"],
    \"TestUserName\": \"${AI_USERNAME}\",
    \"TestUserPwd\": \"${AI_USER_PWD}\",
    \"DBSecurityAdapterDataSource\": \"${DB_SERVICE}\",
    \"DBSecurityAdapterPropagateChange\": false
  }
}"

echo "==> 3. Bootstrapping the Cloud Gateway registry"
api POST /cloudgateway/bootstrapCG "{
  \"registryPort\": \"${GW_REGISTRY_PORT}\",
  \"registryUserName\": \"${AI_USERNAME}\",
  \"registryPassword\": \"${AI_USER_PWD}\",
  \"PrimaryLanguage\": \"${SIEBEL_PRIMARY_LANG}\"
}"

echo "==> 4. Creating the Enterprise profile"
api POST /cloudgateway/profiles/enterprises/ "{
  \"Profile\": {\"ProfileName\": \"enterprise_profile\"},
  \"EnterpriseConfigParams\": {
    \"ServerFileSystem\": \"/sfs\",
    \"UserName\": \"${AI_USERNAME}\",
    \"Password\": \"${AI_USER_PWD}\",
    \"DatabasePlatform\": \"Oracle\",
    \"DBConnectString\": \"${DB_SERVICE}\",
    \"DBUsername\": \"${AI_USERNAME}\",
    \"DBUserPasswd\": \"${AI_USER_PWD}\",
    \"TableOwner\": \"${SIEBEL_TABLEOWNER}\",
    \"SecAdptProfileName\": \"Gateway\",
    \"PrimaryLanguage\": \"${SIEBEL_PRIMARY_LANG}\",
    \"Encrypt\": \"SISNAPITLS\",
    \"CACertFileName\": \"/siebel/pki/truststore.jks\",
    \"KeyFileName\": \"/siebel/pki/keystore.jks\",
    \"KeyFilePassword\": \"${PKI_PWD}\",
    \"PeerAuth\": true,
    \"PeerCertValidation\": true
  }
}"

echo "==> 5. Creating the Server profile"
api POST /cloudgateway/profiles/servers/ "{
  \"Profile\": {\"ProfileName\": \"server_profile\"},
  \"ServerConfigParams\": {
    \"Username\": \"${AI_USERNAME}\",
    \"Password\": \"${AI_USER_PWD}\",
    \"AnonLoginUserName\": \"${SIEBEL_ANON_USER}\",
    \"AnonLoginPassword\": \"${SIEBEL_ANON_PWD}\",
    \"EnableCompGroupsSIA\": \"ADM, CommMgmt, DataQual, EAI, CallCenter, PublicSector, SiebelWebTools, eChannel, Workflow, XMLPReport\",
    \"SCBPort\": \"2321\",
    \"LocalSynchMgrPort\": \"40400\",
    \"ModifyServerEncrypt\": true,
    \"ModifyServerAuth\": true,
    \"Encrypt\": \"SISNAPITLS\",
    \"CertFileNameServer\": \"/siebel/pki/keystore.jks\",
    \"CACertFileName\": \"/siebel/pki/truststore.jks\",
    \"ClusteringEnvironmentSetup\": \"NotClustered\",
    \"UseOracleConnector\": \"true\"
  }
}"

echo "==> 6. Creating the Application Interface profile"
api POST /cloudgateway/profiles/swsm/ "{
  \"Profile\": {\"ProfileName\": \"ai_profile\"},
  \"ConfigParam\": {
    \"defaults\": {
      \"DoCompression\": true,
      \"EnableFQDN\": false,
      \"AuthenticationProperties\": {
        \"SessionTimeout\": 900,
        \"GuestSessionTimeout\": 300,
        \"SessionTimeoutWLMethod\": \"HeartBeat\",
        \"SessionTimeoutWLCommand\": \"UpdatePrefMsg\",
        \"SessionTokenMaxAge\": 2880,
        \"SessionTokenTimeout\": 900,
        \"SingleSignOn\": false,
        \"AnonUserName\": \"${SIEBEL_ANON_USER}\",
        \"AnonPassword\": \"${SIEBEL_ANON_PWD}\"
      }
    },
    \"RESTInBound\": {
      \"RESTAuthenticationProperties\": {
        \"AnonUserName\": \"${SIEBEL_ANON_USER}\",
        \"AnonPassword\": \"${SIEBEL_ANON_PWD}\",
        \"AuthenticationType\": \"Basic\",
        \"SessKeepAlive\": 10,
        \"ValidateCertificate\": true
      },
      \"LogProperties\": {\"LogLevel\": \"ERROR\"},
      \"ObjectManager\": \"eaiobjmgr_${SIEBEL_PRIMARY_LANG}\",
      \"Baseuri\": \"${MDE_HOSTNAME}.${PKI_DOMAIN}:${AI_REDIRECT_PORT}/siebel/v1.0/\",
      \"MaxConnections\": 20,
      \"RESTResourceParamList\": []
    },
    \"UI\": {\"LogProperties\": {\"LogLevel\": \"ERROR\"}},
    \"EAI\": {\"LogProperties\": {\"LogLevel\": \"ERROR\"}},
    \"DAV\": {\"LogProperties\": {\"LogLevel\": \"ERROR\"}},
    \"RESTOutBound\": {\"LogProperties\": {\"LogLevel\": \"ERROR\"}},
    \"SOAPOutBound\": {\"LogProperties\": {\"LogLevel\": \"ERROR\"}},
    \"Applications\": [
      {
        \"Name\": \"eai\",
        \"ObjectManager\": \"eaiobjmgr_${SIEBEL_PRIMARY_LANG}\",
        \"Language\": \"${SIEBEL_PRIMARY_LANG}\",
        \"StartCommand\": \"\",
        \"EnableExtServiceOnly\": false,
        \"AvailableInSiebelMobile\": false,
        \"AuthenticationProperties\": {
          \"SessionTimeout\": 900,
          \"GuestSessionTimeout\": 300,
          \"SessionTimeoutWLMethod\": \"HeartBeat\",
          \"SessionTimeoutWLCommand\": \"UpdatePrefMsg\",
          \"SessionTokenMaxAge\": 2880,
          \"SessionTokenTimeout\": 900,
          \"SingleSignOn\": false,
          \"AnonUserName\": \"${SIEBEL_ANON_USER}\",
          \"AnonPassword\": \"${SIEBEL_ANON_PWD}\"
        }
      },
      {
        \"Name\": \"publicsector\",
        \"ObjectManager\": \"psccobjmgr_${SIEBEL_PRIMARY_LANG}\",
        \"Language\": \"${SIEBEL_PRIMARY_LANG}\",
        \"StartCommand\": \"\",
        \"EnableExtServiceOnly\": false,
        \"AvailableInSiebelMobile\": false,
        \"AuthenticationProperties\": {
          \"SessionTimeout\": 900,
          \"GuestSessionTimeout\": 300,
          \"SessionTimeoutWLMethod\": \"HeartBeat\",
          \"SessionTimeoutWLCommand\": \"UpdatePrefMsg\",
          \"SessionTokenMaxAge\": 2880,
          \"SessionTokenTimeout\": 900,
          \"SingleSignOn\": false,
          \"AnonUserName\": \"${SIEBEL_ANON_USER}\",
          \"AnonPassword\": \"${SIEBEL_ANON_PWD}\"
        }
      },
      {
        \"Name\": \"callcenter\",
        \"ObjectManager\": \"sccobjmgr_${SIEBEL_PRIMARY_LANG}\",
        \"Language\": \"${SIEBEL_PRIMARY_LANG}\",
        \"StartCommand\": \"\",
        \"EnableExtServiceOnly\": false,
        \"AvailableInSiebelMobile\": false,
        \"AuthenticationProperties\": {
          \"SessionTimeout\": 900,
          \"GuestSessionTimeout\": 300,
          \"SessionTimeoutWLMethod\": \"HeartBeat\",
          \"SessionTimeoutWLCommand\": \"UpdatePrefMsg\",
          \"SessionTokenMaxAge\": 2880,
          \"SessionTokenTimeout\": 900,
          \"SingleSignOn\": false,
          \"AnonUserName\": \"${SIEBEL_ANON_USER}\",
          \"AnonPassword\": \"${SIEBEL_ANON_PWD}\"
        }
      }
    ],
    \"RESTInBoundResource\": [{\"ResourceType\": \"Data\", \"RESTResourceParamList\": []}],
    \"swe\": {
      \"Language\": \"ENU\",
      \"MaxQueryStringLength\": -1,
      \"SeedFile\": \"\",
      \"SessionMonitor\": false,
      \"AllowStats\": true
    }
  }
}"

echo "==> 7. Deploying the Enterprise"
api POST /cloudgateway/deployments/enterprises/ "{
  \"DeploymentInfo\": {\"ProfileName\": \"enterprise_profile\", \"Action\": \"Deploy\"},
  \"EnterpriseDeployParams\": {
    \"SiebelEnterprise\": \"${SIEBEL_ENTERPRISE}\",
    \"EnterpriseDesc\": \"${SIEBEL_ENTERPRISE} Enterprise\"
  }
}"
wait_for_deployed "/cloudgateway/deployments/enterprises/${SIEBEL_ENTERPRISE}"

echo "==> 8. Deploying the Server"
api POST /cloudgateway/deployments/servers/ "{
  \"DeploymentInfo\": {
    \"PhysicalHostIP\": \"${MDE_HOSTNAME}.${PKI_DOMAIN}:${SES_REDIRECT_PORT}\",
    \"ProfileName\": \"server_profile\",
    \"Action\": \"Deploy\"
  },
  \"ServerDeployParams\": {
    \"SiebelServer\": \"siebses1\",
    \"SiebelServerDesc\": \"siebses1 Siebel Application Server\",
    \"DeployedLanguage\": \"${SIEBEL_PRIMARY_LANG}\"
  }
}"
wait_for_deployed "/cloudgateway/deployments/servers/siebses1"

echo "==> 9. Deploying the Application Interface"
api POST /cloudgateway/deployments/swsm/ "{
  \"DeploymentInfo\": {
    \"PhysicalHostIP\": \"${MDE_HOSTNAME}.${PKI_DOMAIN}:${AI_REDIRECT_PORT}\",
    \"ProfileName\": \"ai_profile\",
    \"Action\": \"Deploy\"
  },
  \"DeploymentParam\": {
    \"Node\": \"siebsai1\",
    \"NodeDesc\": \"siebsai1 Siebel Application Interface Node\"
  }
}"

echo "==> Bootstrap complete. Siebel should be reachable at https://localhost/siebel/app/${SIEBEL_PRIMARY_LANG}"
