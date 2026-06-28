# Siebel Application Interface (SAI) Image

**Image tag:** `ol8/siebel/sai-base:24.9np`
**Dockerfile:** `docker/sai/Dockerfile`
**Base:** `oraclelinux:8-slim` (not the instantclient image)

The Application Interface is the web tier — the Tomcat-based server that serves the Siebel web UI to browsers. It acts as a reverse proxy between users and the Siebel Server. This is the component users hit directly, accessible on port 443.

SAI builds directly from Oracle Linux slim rather than the instantclient image because it has no Oracle database client dependency — all database communication goes through the Siebel Server.

## Build args

| ARG | Default | Purpose |
|---|---|---|
| `OL_VERSION` | `8` | Oracle Linux version for the base image |
| `SIEBEL_VERSION` | `24.9` | Siebel version label |
| `SIEBEL_USER` | `oracle` | OS user that owns the Siebel installation |
| `SIEBEL_GROUP` | `oinstall` | OS group |
| `SIEBEL_UID` | `29263` | UID for the oracle user |
| `SIEBEL_GID` | `29263` | GID for the oinstall group |
| `PKI_PWD` | _(required)_ | Password for the SSL keystore |
| `PKI_DOMAIN` | `company.com` | Domain used in the certificate SAN |
| `AI_HTTP_PORT` | `6090` | SAI Tomcat HTTP port |
| `AI_SHUTDOWN_PORT` | `6092` | SAI Tomcat shutdown port |
| `AI_REDIRECT_PORT` | `6091` | SAI Tomcat redirect port (mapped to host port 443) |
| `AI_USERNAME` | `SADMIN` | Siebel admin username embedded in the response file |
| `AI_USER_PWD` | _(required)_ | SADMIN password — encrypted separately from the PKI password |

## Dockerfile steps

**1. Base and package bootstrap**
Starts from `oraclelinux:8-slim`. Because the slim image only ships with `microdnf`, the first `RUN` installs `dnf` before the main package installation step.

**2. COPY config files and installer**
Same as the other images — config files to `/config/`, Siebel installer to `/mnt/Siebel_Enterprise_Server/`.

**3. RUN — all build steps in one layer**

- Creates directories, group, and user (same as CGW/SES)
- Installs OS packages via `dnf` (same package list as CGW/SES)
- Generates the SSL keystore and CA-signed certificate (same PKI process as CGW/SES)

*Two password encryptions (unique to SAI and MDE):*
- Runs `EncryptString.jar` with `PKI_PWD` to produce `PKI_ENCRYPTED`
- Runs `EncryptString.jar` again with `AI_USER_PWD` to produce `AI_PWD_ENCRYPTED`

*Response file substitution:*
- Substitutes encrypted PKI password, encrypted admin password, admin username, and all three AI ports into `/config/sai.rsp`

*Installation and cleanup:*
- Same as CGW/SES — runs `setup.sh` as oracle, removes installer, sleeps 30 seconds, sets permissions

**4. ENV and EXPOSE**
Same environment variables as the other components. Exposes port `6091` (the AI redirect port), which is mapped to host port 443.

## Config files

| File | Purpose |
|---|---|
| `sai.rsp` | Siebel silent installer response file. Configures an AI-only installation (`ENTERPRISE_CONTAINER_CONFIGURATION=false`, `AI_CONTAINER_CONFIGURATION=true`). Contains `@@PLACEHOLDER@@` values for the AI ports, admin username, encrypted admin password, and encrypted PKI password. |
| `oraInst.loc` | Tells the Oracle installer where to write its inventory. |
| `setup.sh` | Runs the Siebel silent installer as the `oracle` user using the SAI response file. |
| `start_03_sai_tomcat.sh` | Sources the Tomcat environment from `applicationcontainer_external` and starts it. SAI uses the `_external` container (outward-facing web tier) as opposed to the `_internal` management container used by CGW and SES. |
| `stop_01_sai_tomcat.sh` | Shuts down the SAI Tomcat container. |
| `persistenceLayerSAI` | Bash arrays listing the small set of files that must survive container restarts — primarily Tomcat configuration, the application interface properties, migration logs, and the keystore. |
| `kernelCheck` | Checks the Linux kernel version for known Siebel incompatibilities. |
| `initSAI` | Container init script. Runs `kernelCheck`, migrates persistent content to `/persistent`, sets up custom JS/CSS context paths in Tomcat's `server.xml`, then starts Tomcat. Unlike CGW and SES, initSAI starts Tomcat directly as part of its init sequence. |
