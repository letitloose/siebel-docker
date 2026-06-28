# Siebel MDE (Modular Deployment Engine) Image

**Image tag:** `ol8/siebel/mde-base:24.9np`
**Dockerfile:** `docker/mde/Dockerfile`
**Base:** `ol8/instantclient/32bit:19.31`

The MDE is a self-contained Siebel stack in a single container — it combines the Cloud Gateway, Siebel Enterprise Server, and Application Interface. It is used for development and deployment automation (bootstrapping a new Siebel enterprise, deploying configuration changes) without needing three separate containers running. The Management Console (SMC) communicates with the MDE to configure and deploy the full stack.

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
| `SES_HTTP_PORT` | `5090` | Enterprise Server Tomcat HTTP port |
| `SES_SHUTDOWN_PORT` | `5092` | Enterprise Server Tomcat shutdown port |
| `SES_REDIRECT_PORT` | `5091` | Enterprise Server Tomcat redirect port |
| `AI_HTTP_PORT` | `6090` | Application Interface Tomcat HTTP port |
| `AI_SHUTDOWN_PORT` | `6092` | Application Interface Tomcat shutdown port |
| `AI_REDIRECT_PORT` | `6091` | Application Interface Tomcat redirect port |
| `AI_USERNAME` | `SADMIN` | Siebel admin username |
| `AI_USER_PWD` | _(required)_ | SADMIN password — encrypted separately from PKI |
| `GW_TLS_PORT` | `2320` | Gateway TLS port used in `start_srvrmgr.sh` |
| `SIEBEL_ENTERPRISE` | `dev01` | Enterprise name used in `start_srvrmgr.sh` |
| `MDE_HOSTNAME` | `dev01mde01` | Container hostname used to connect to the gateway |

## Dockerfile steps

The build process follows the same structure as CGW and SES but with additional steps.

**1–2. COPY and OS setup**
Same as CGW/SES — config files, installer, directory creation, user/group creation, package installation.

**3. PKI keystore generation**
Identical to CGW/SES/SAI.

**4. Two password encryptions**
Same as SAI — PKI password and SADMIN password are encrypted independently using `EncryptString.jar`.

**5. Response file and script substitution**
- `mde.rsp` receives all ports (both EC and AI sections) plus both encrypted passwords and the admin username
- `start_srvrmgr.sh` receives `MDE_HOSTNAME`, `PKI_DOMAIN`, `GW_TLS_PORT`, `AI_USERNAME`, and `SIEBEL_ENTERPRISE` — these are baked into the script at build time. The SADMIN password is left as `${AI_USER_PWD}` so it is read from the container's runtime environment.

**6. Installation and cleanup**
Same as CGW/SES, except `chmod -R 755 /siebel` applies to the entire tree rather than a single component subdirectory.

**7. ENV and EXPOSE**
Same environment variables. Exposes two ports: `6091` (AI redirect, mapped to 4443 on the host) and `2322` (gateway registry port).

## Config files

| File | Purpose |
|---|---|
| `mde.rsp` | Siebel silent installer response file. Installs all three components (`ENTERPRISE_CONTAINER_CONFIGURATION=true`, `AI_CONTAINER_CONFIGURATION=true`). Contains placeholders for both EC and AI port sections, the admin username, the encrypted admin password, and the encrypted PKI password across four keystore entries (EC and AI each have a keystore and truststore). |
| `oraInst.loc` | Tells the Oracle installer where to write its inventory. |
| `setup.sh` | Runs the Siebel silent installer as the `oracle` user using the MDE response file. |
| `start_ai_internal.sh` | Starts the internal Tomcat container (gateway management interface). |
| `stop_ai_internal.sh` | Stops the internal Tomcat container. |
| `start_ai_external.sh` | Starts the external Tomcat container (Application Interface web tier). |
| `stop_ai_external.sh` | Stops the external Tomcat container. |
| `start_01_gateway.sh` | Sources the environment and starts the Zookeeper-based name server (`start_ns`). |
| `stop_02_gateway.sh` | Stops the name server (`stop_ns`). |
| `start_02_siebsrvr.sh` | Starts all Siebel Server processes (`start_server all`). |
| `stop_01_siebsrvr.sh` | Stops all Siebel Server processes and runs `mwadm stop`. |
| `start_srvrmgr.sh` | Connects to the MDE's own gateway using `srvrmgr` for interactive server management. The gateway hostname, TLS port, enterprise name, and username are baked in at build time; the password is read from the `AI_USER_PWD` environment variable at runtime. |
| `persistenceLayerSiebel-MDE` | The largest persistence layer — covers gateway, server, and AI files across all three subsystems including multi-language configuration files for all supported locales. |
| `kernelCheck` | Checks the Linux kernel version for known Siebel incompatibilities. |
| `initSiebelmde` | Container init script. Runs `kernelCheck`, then migrates all persistent content across all three subsystems to `/persistent`. |
