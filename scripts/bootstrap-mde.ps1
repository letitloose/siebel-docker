# Bootstraps the Siebel Enterprise inside the MDE container.
# PowerShell equivalent of bootstrap-mde.sh — see docs/bootstrap.md.
#
# Requirements: Docker Desktop with WSL2 backend, curl.exe (built into
# Windows 10 1803+), PowerShell 5.1 or 7+.
#
# Run from the project root:
#   .\scripts\bootstrap-mde.ps1

$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

# Load .env
Get-Content .env | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]+?)\s*=\s*(.*)\s*$') {
        Set-Variable -Name $Matches[1].Trim() -Value $Matches[2].Trim() -Scope Script
    }
}

$MDE_URL   = "https://localhost:4443/siebel/v1.0"
$AUTH      = "${AI_USERNAME}:$AI_USER_PWD"
$MAX_TIME  = 120

$SIEBEL_TABLEOWNER = "SIEBEL"
$SIEBEL_ANON_USER  = "GUESTCST"
# Expected number of '. . imported' lines in the impdp log for Siebel 24.9.
# Update if you switch to a different dump version.
$IMPORT_OBJECT_TOTAL = 5665

# Invokes a Cloud Gateway REST API call and returns the response body.
# Uses curl.exe explicitly to avoid PowerShell's Invoke-WebRequest alias.
function Invoke-Api {
    param(
        [string]$Method,
        [string]$Path,
        [string]$Body = ""
    )
    $url = "${MDE_URL}$Path"
    if ($Body) {
        $tmp = "$env:TEMP\siebel_body.json"
        [System.IO.File]::WriteAllText($tmp, $Body, [System.Text.Encoding]::UTF8)
        $response = curl.exe -sk --max-time $MAX_TIME -X $Method $url `
            --user $AUTH `
            -H "Content-Type: application/json" `
            --data-binary "@$tmp"
    } else {
        $response = curl.exe -sk --max-time $MAX_TIME -X $Method $url `
            --user $AUTH
    }
    Write-Host ($response -join "`n")
    return ($response -join "`n")
}

# Polls a deployment endpoint until it reports Deployed (max 60 minutes).
function Wait-ForDeployed {
    param([string]$Path)
    $maxRetries = 360
    $attempt    = 0
    Write-Host "Waiting for $Path to report Deployed..."
    while ($true) {
        $ts       = Get-Date -Format "HH:mm:ss"
        $response = curl.exe -sk --max-time $MAX_TIME "${MDE_URL}$Path" --user $AUTH
        $body     = $response -join "`n"
        Write-Host "[$ts] attempt=$attempt response=$body"
        if ($body -match '"Status"\s*:\s*"Deployed"') {
            Write-Host "[$ts] Matched Deployed - proceeding"
            break
        }
        $attempt++
        if ($attempt -ge $maxRetries) {
            Write-Error "ERROR: $Path did not report Deployed after $($maxRetries * 10)s. Aborting."
            exit 1
        }
        Start-Sleep -Seconds 10
    }
}

Write-Host "==> Recreating the mde container for a guaranteed clean starting state"
docker compose up -d --force-recreate mde

Write-Host "==> Waiting for Siebel schema to be ready"
Write-Host "    On first run this takes ~2 hours (DB creation + schema import). Polling every 5 minutes..."
while ($true) {
    $result = docker compose exec -T oracle19c bash -c `
        "echo 'SELECT count(*) FROM siebel.s_app_ver;' | timeout 30 sqlplus -s sys/${ORACLE_PWD}@//localhost:1521/ORCLPDB1 as sysdba" 2>$null |
        Select-String '^\s*[1-9][0-9]*\s*$' | Select-Object -First 1
    $ts = Get-Date -Format "HH:mm:ss"
    if ($result) { Write-Host "    [$ts] Siebel schema ready."; break }
    $imported = (docker compose exec -T oracle19c grep -c '. . imported' /opt/oracle/dumps/impdp_siebel.log 2>$null) -as [int]
    if (-not $imported) { $imported = 0 }
    $lastObj = docker compose logs oracle19c 2>$null |
        Select-String "Processing object type" | Select-Object -Last 1 |
        ForEach-Object { ($_.Line -split "Processing object type ")[-1] }
    if (-not $lastObj) { $lastObj = "waiting for import to start" }
    Write-Host "    [$ts] $imported/$IMPORT_OBJECT_TOTAL objects imported - phase: $lastObj"
    Write-Host "                    Next check in 5 minutes..."
    Start-Sleep -Seconds 300
}

Write-Host "==> Starting MDE internal and external Tomcat"
docker compose exec -T --workdir /config mde bash ./start_ai_internal.sh
docker compose exec -T --workdir /config mde bash ./start_ai_external.sh

Write-Host "==> Waiting for the Cloud Gateway REST API to respond"
while ($true) {
    $result = curl.exe -sk --max-time $MAX_TIME -o NUL -w "%{http_code}" "${MDE_URL}/cginfo" 2>$null
    if ($result -match '^\d{3}$') { break }
    Start-Sleep -Seconds 5
}

Write-Host "==> 1. Setting Cloud Gateway host info"
$body = [ordered]@{
    CGHostURI = "${MDE_HOSTNAME}.${PKI_DOMAIN}:$SES_REDIRECT_PORT"
    CGTlsPort = $GW_TLS_PORT
} | ConvertTo-Json -Compress
Invoke-Api POST /cginfo $body

Write-Host "==> 2. Configuring the Gateway security profile (DB-backed authentication)"
$body = [ordered]@{
    Profile = [ordered]@{ ProfileName = "Siebel" }
    SecurityConfigParams = [ordered]@{
        DataSources = @(
            [ordered]@{
                Name          = $DB_SERVICE
                Type          = "DB"
                Host          = $DB_HOST
                Port          = $DB_PORT
                SqlStyle      = "Oracle"
                Endpoint      = $DB_SERVICE
                TableOwner    = $SIEBEL_TABLEOWNER
                HashUserPwd   = $false
                HashAlgorithm = "SHA1"
                CRC           = ""
            }
        )
        SecAdptName                      = "DBSecAdpt"
        SecAdptMode                      = "DB"
        NSAdminRole                      = @("Siebel Administrator")
        TestUserName                     = $AI_USERNAME
        TestUserPwd                      = $AI_USER_PWD
        DBSecurityAdapterDataSource      = $DB_SERVICE
        DBSecurityAdapterPropagateChange = $false
    }
} | ConvertTo-Json -Compress -Depth 10
Invoke-Api POST /cloudgateway/GatewaySecurityProfile $body

Write-Host "==> 3. Bootstrapping the Cloud Gateway registry"
$body = [ordered]@{
    registryPort     = $GW_REGISTRY_PORT
    registryUserName = $AI_USERNAME
    registryPassword = $AI_USER_PWD
    PrimaryLanguage  = $SIEBEL_PRIMARY_LANG
} | ConvertTo-Json -Compress
Invoke-Api POST /cloudgateway/bootstrapCG $body

Write-Host "==> 4. Creating the Enterprise profile"
$body = [ordered]@{
    Profile = [ordered]@{ ProfileName = "enterprise_profile" }
    EnterpriseConfigParams = [ordered]@{
        ServerFileSystem    = "/sfs"
        UserName            = $AI_USERNAME
        Password            = $AI_USER_PWD
        DatabasePlatform    = "Oracle"
        DBConnectString     = $DB_SERVICE
        DBUsername          = $AI_USERNAME
        DBUserPasswd        = $AI_USER_PWD
        TableOwner          = $SIEBEL_TABLEOWNER
        SecAdptProfileName  = "Gateway"
        PrimaryLanguage     = $SIEBEL_PRIMARY_LANG
        Encrypt             = "SISNAPITLS"
        CACertFileName      = "/siebel/pki/truststore.jks"
        KeyFileName         = "/siebel/pki/keystore.jks"
        KeyFilePassword     = $PKI_PWD
        PeerAuth            = $true
        PeerCertValidation  = $true
    }
} | ConvertTo-Json -Compress -Depth 5
Invoke-Api POST /cloudgateway/profiles/enterprises/ $body

Write-Host "==> 5. Creating the Server profile"
$body = [ordered]@{
    Profile = [ordered]@{ ProfileName = "server_profile" }
    ServerConfigParams = [ordered]@{
        Username                    = $AI_USERNAME
        Password                    = $AI_USER_PWD
        AnonLoginUserName           = $SIEBEL_ANON_USER
        AnonLoginPassword           = $SIEBEL_ANON_PWD
        EnableCompGroupsSIA         = "ADM, CommMgmt, DataQual, EAI, CallCenter, PublicSector, SiebelWebTools, eChannel, Workflow, XMLPReport"
        SCBPort                     = "2321"
        LocalSynchMgrPort           = "40400"
        ModifyServerEncrypt         = $true
        ModifyServerAuth            = $true
        Encrypt                     = "SISNAPITLS"
        CertFileNameServer          = "/siebel/pki/keystore.jks"
        CACertFileName              = "/siebel/pki/truststore.jks"
        ClusteringEnvironmentSetup  = "NotClustered"
        UseOracleConnector          = "true"
    }
} | ConvertTo-Json -Compress -Depth 5
Invoke-Api POST /cloudgateway/profiles/servers/ $body

Write-Host "==> 6. Creating the Application Interface profile"
$ap = [ordered]@{
    SessionTimeout          = 900
    GuestSessionTimeout     = 300
    SessionTimeoutWLMethod  = "HeartBeat"
    SessionTimeoutWLCommand = "UpdatePrefMsg"
    SessionTokenMaxAge      = 2880
    SessionTokenTimeout     = 900
    SingleSignOn            = $false
    AnonUserName            = $SIEBEL_ANON_USER
    AnonPassword            = $SIEBEL_ANON_PWD
}
$body = [ordered]@{
    Profile = [ordered]@{ ProfileName = "ai_profile" }
    ConfigParam = [ordered]@{
        defaults = [ordered]@{
            DoCompression           = $true
            EnableFQDN              = $false
            AuthenticationProperties = $ap
        }
        RESTInBound = [ordered]@{
            RESTAuthenticationProperties = [ordered]@{
                AnonUserName         = $SIEBEL_ANON_USER
                AnonPassword         = $SIEBEL_ANON_PWD
                AuthenticationType   = "Basic"
                SessKeepAlive        = 10
                ValidateCertificate  = $true
            }
            LogProperties  = [ordered]@{ LogLevel = "ERROR" }
            ObjectManager  = "eaiobjmgr_$SIEBEL_PRIMARY_LANG"
            Baseuri        = "${MDE_HOSTNAME}.${PKI_DOMAIN}:${AI_REDIRECT_PORT}/siebel/v1.0/"
            MaxConnections = 20
            RESTResourceParamList = @()
        }
        UI           = [ordered]@{ LogProperties = [ordered]@{ LogLevel = "ERROR" } }
        EAI          = [ordered]@{ LogProperties = [ordered]@{ LogLevel = "ERROR" } }
        DAV          = [ordered]@{ LogProperties = [ordered]@{ LogLevel = "ERROR" } }
        RESTOutBound = [ordered]@{ LogProperties = [ordered]@{ LogLevel = "ERROR" } }
        SOAPOutBound = [ordered]@{ LogProperties = [ordered]@{ LogLevel = "ERROR" } }
        Applications = @(
            [ordered]@{ Name = "eai";          ObjectManager = "eaiobjmgr_$SIEBEL_PRIMARY_LANG";  Language = $SIEBEL_PRIMARY_LANG; StartCommand = ""; EnableExtServiceOnly = $false; AvailableInSiebelMobile = $false; AuthenticationProperties = $ap },
            [ordered]@{ Name = "publicsector"; ObjectManager = "psccobjmgr_$SIEBEL_PRIMARY_LANG"; Language = $SIEBEL_PRIMARY_LANG; StartCommand = ""; EnableExtServiceOnly = $false; AvailableInSiebelMobile = $false; AuthenticationProperties = $ap },
            [ordered]@{ Name = "callcenter";   ObjectManager = "sccobjmgr_$SIEBEL_PRIMARY_LANG";  Language = $SIEBEL_PRIMARY_LANG; StartCommand = ""; EnableExtServiceOnly = $false; AvailableInSiebelMobile = $false; AuthenticationProperties = $ap }
        )
        RESTInBoundResource = @( [ordered]@{ ResourceType = "Data"; RESTResourceParamList = @() } )
        swe = [ordered]@{
            Language           = "ENU"
            MaxQueryStringLength = -1
            SeedFile           = ""
            SessionMonitor     = $false
            AllowStats         = $true
        }
    }
} | ConvertTo-Json -Compress -Depth 20
Invoke-Api POST /cloudgateway/profiles/swsm/ $body

Write-Host "==> 7. Deploying the Enterprise"
$body = [ordered]@{
    DeploymentInfo = [ordered]@{ ProfileName = "enterprise_profile"; Action = "Deploy" }
    EnterpriseDeployParams = [ordered]@{
        SiebelEnterprise = $SIEBEL_ENTERPRISE
        EnterpriseDesc   = "${SIEBEL_ENTERPRISE} Enterprise"
    }
} | ConvertTo-Json -Compress -Depth 5
Invoke-Api POST /cloudgateway/deployments/enterprises/ $body
Wait-ForDeployed "/cloudgateway/deployments/enterprises/$SIEBEL_ENTERPRISE"

Write-Host "==> 8. Deploying the Server"
$body = [ordered]@{
    DeploymentInfo = [ordered]@{
        PhysicalHostIP = "${MDE_HOSTNAME}.${PKI_DOMAIN}:$SES_REDIRECT_PORT"
        ProfileName    = "server_profile"
        Action         = "Deploy"
    }
    ServerDeployParams = [ordered]@{
        SiebelServer     = "siebses1"
        SiebelServerDesc = "siebses1 Siebel Application Server"
        DeployedLanguage = $SIEBEL_PRIMARY_LANG
    }
} | ConvertTo-Json -Compress -Depth 5
Invoke-Api POST /cloudgateway/deployments/servers/ $body
Wait-ForDeployed "/cloudgateway/deployments/servers/siebses1"

Write-Host "==> 9. Deploying the Application Interface"
$body = [ordered]@{
    DeploymentInfo = [ordered]@{
        PhysicalHostIP = "${MDE_HOSTNAME}.${PKI_DOMAIN}:$AI_REDIRECT_PORT"
        ProfileName    = "ai_profile"
        Action         = "Deploy"
    }
    DeploymentParam = [ordered]@{
        Node     = "siebsai1"
        NodeDesc = "siebsai1 Siebel Application Interface Node"
    }
} | ConvertTo-Json -Compress -Depth 5
Invoke-Api POST /cloudgateway/deployments/swsm/ $body

Write-Host "==> Bootstrap complete. Siebel should be reachable at https://localhost:4443/siebel/app/$SIEBEL_PRIMARY_LANG"

