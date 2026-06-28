# Siebel Enterprise Server (SES) Image

**Image tag:** `ol8/siebel/ses-base:24.9np`
**Dockerfile:** `docker/ses/Dockerfile`
**Base:** `ol8/instantclient/32bit:19.31`

The Siebel Enterprise Server hosts the Siebel application server processes (component groups such as Call Center, Workflow, EAI, etc.). It registers with the Cloud Gateway on startup and receives its configuration from there.

## Build args

| ARG | Default | Purpose |
|---|---|---|
| `INSTANTCLIENT_IMAGE` | `ol8/instantclient/32bit:19.31` | Base image tag |
| `SIEBEL_VERSION` | `24.9` | Siebel version label |
| `SIEBEL_USER` | `oracle` | OS user that owns the Siebel installation |
| `SIEBEL_GROUP` | `oinstall` | OS group |
| `SIEBEL_UID` | `29263` | UID for the oracle user |
| `SIEBEL_GID` | `29263` | GID for the oinstall group |
| `PKI_PWD` | _(required)_ | Password for the SSL keystore |
| `PKI_DOMAIN` | `company.com` | Domain used in the certificate SAN |
| `SES_HTTP_PORT` | `5090` | Server Tomcat HTTP port |
| `SES_SHUTDOWN_PORT` | `5092` | Server Tomcat shutdown port |
| `SES_REDIRECT_PORT` | `5091` | Server Tomcat redirect port |

## Dockerfile steps

The steps are identical in structure to the CGW image — OS package install, keystore generation, password encryption, response file substitution, silent install, cleanup. The differences are the component name (`ses`), ports, and response file.

See [cgw.md](cgw.md) for a detailed step-by-step description of the shared build process.

## Config files

| File | Purpose |
|---|---|
| `ses.rsp` | Siebel silent installer response file. Same flags as CGW (`ENTERPRISE_CONTAINER_CONFIGURATION=true`, `AI_CONTAINER_CONFIGURATION=false`). Contains `@@PLACEHOLDER@@` values for the server ports and encrypted PKI password. |
| `oraInst.loc` | Tells the Oracle installer where to write its inventory. |
| `setup.sh` | Runs the Siebel silent installer as the `oracle` user using the SES response file. |
| `start_02_siebsrvr.sh` | Sources the Oracle environment, starts the Tomcat-based management container, waits 10 seconds, then starts all Siebel Server processes (`start_server all`). |
| `stop_02_siebsrvr.sh` | Stops all Siebel Server processes, runs `mwadm stop`, then shuts down the Tomcat container. Calls `stop_server all` twice to ensure a clean shutdown. |
| `start_02_siebsrvr_tomcat.sh` | Starts only the Tomcat management container without starting Siebel Server processes. |
| `stop_02_siebsrvr_tomcat.sh` | Shuts down only the Tomcat management container. |
| `persistenceLayerSES` | Bash arrays listing files and directories in the SES installation that must survive container restarts — includes Siebel Server configuration, log directories, enterprise definitions, and language-specific config files. Sourced by `initSES`. |
| `kernelCheck` | Checks the Linux kernel version for known Siebel incompatibilities. |
| `initSES` | Container init script. Runs `kernelCheck`, then migrates all persistent content to the `/persistent` bind mount and replaces originals with symlinks. |
