# Siebel Cloud Gateway (CGW) Image

**Image tag:** `ol8/siebel/cgw-base:24.9np`
**Dockerfile:** `docker/cgw/Dockerfile`
**Base:** `ol8/instantclient/32bit:19.31`

The Cloud Gateway is the central registry and name server for the Siebel enterprise. It is built on Apache Zookeeper and all other Siebel components register with it on startup. Nothing else in the stack can function without the gateway running.

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
| `PKI_DOMAIN` | `company.com` | Domain used in the certificate SAN (`*.company.com`) |
| `GW_HTTP_PORT` | `4091` | Gateway Tomcat HTTP port |
| `GW_SHUTDOWN_PORT` | `4092` | Gateway Tomcat shutdown port |
| `GW_REDIRECT_PORT` | `4090` | Gateway Tomcat redirect port |

## Dockerfile steps

**1. COPY config files**
Copies everything from `docker/cgw/config/` into `/config/` inside the image — response file, setup script, start/stop scripts, persistence layer, kernel check, and init script.

**2. COPY Siebel installer**
Copies the full `software/Siebel_Enterprise_Server/` tree into `/mnt/Siebel_Enterprise_Server/`. This is removed after installation to keep the final image size down.

**3. RUN — all build steps in one layer**

- Creates `/siebel/cgw`, `/siebel/oraInventory`, and `/stage` directories
- Creates the `oinstall` group and `oracle` user with the specified UID/GID
- Updates `libstdc++` and installs all required OS packages including `openssl` and `java-1.8.0-openjdk-headless`
- Cleans package caches

*PKI keystore generation:*
- Generates an RSA 2048-bit self-signed keypair with alias `siebel` using `keytool`
- Creates a Certificate Signing Request (CSR)
- Generates a CA private key and self-signed CA certificate using `openssl`
- Signs the CSR with the CA certificate to produce a CA-signed certificate
- Imports both the CA cert and the signed cert back into the keystore
- Copies the finished `siebelkeystore.jks` to `/config/`

*Password encryption:*
- Runs `EncryptString.jar` (from the Siebel installer) with the `PKI_PWD` build arg to produce the Siebel-format encrypted password

*Response file substitution:*
- Uses `sed` to replace all `@@PLACEHOLDER@@` values in `/config/cgw.rsp` with the encrypted password and port numbers

*Installation:*
- Sets ownership of the installer and `/siebel` to the `oracle` user
- Runs `setup.sh` as the `oracle` user, which invokes the Siebel silent installer
- Removes the installer directory and PKI temp files
- Sleeps 30 seconds to allow the installer's background processes to complete
- Sets permissions on `/siebel/cgw`

**4. ENV**
Sets `RESOLV_MULTI=off`, `LANG`, `JAVA_OPTS`, `LIBPATH`, and `SIEBEL_UNIXUNICODE_DB=ORACLE`.

## Config files

| File | Purpose |
|---|---|
| `cgw.rsp` | Siebel silent installer response file. Configures a gateway-only installation (`ENTERPRISE_CONTAINER_CONFIGURATION=true`, `AI_CONTAINER_CONFIGURATION=false`). Contains `@@PLACEHOLDER@@` values for ports and the encrypted PKI password that are substituted at build time. |
| `oraInst.loc` | Tells the Oracle installer where to write its inventory (`/siebel/oraInventory`) and which group owns it. |
| `setup.sh` | Runs the Siebel silent installer as the `oracle` user using the response file. |
| `start_01_gateway.sh` | Sources the Oracle environment, starts the Tomcat-based gateway container, waits 10 seconds, then starts the Zookeeper-based name server (`start_ns`). |
| `stop_03_gateway.sh` | Stops the name server (`stop_ns`) then shuts down the Tomcat gateway container. |
| `start_01_gateway_tomcat.sh` | Starts only the Tomcat component of the gateway (without the name server). Used for stepwise startup. |
| `stop_03_gateway_tomcat.sh` | Shuts down only the Tomcat component. |
| `persistenceLayerCGW` | Bash arrays (`folderList`, `fileList`) listing every file and directory in the Siebel installation that must survive container restarts. Sourced by `initCGW` at runtime. |
| `kernelCheck` | Checks the Linux kernel version for known incompatibilities with Siebel's 32-bit binaries. Exits non-zero if the kernel is in a bad range. |
| `initCGW` | The container init script. Runs `kernelCheck`, then migrates all persistent files and directories (listed in `persistenceLayerCGW`) from the image into the `/persistent` bind mount, replacing them with symlinks. This ensures configuration survives container restarts. |
