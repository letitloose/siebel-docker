# Siebel Image Differences

All five images share a common pattern: install OS dependencies, generate the SSL keystore, encrypt passwords, substitute values into config files, run the Siebel silent installer, and clean up. This document covers where they diverge.

## Base image

| Image | Base |
|---|---|
| instantclient | `oraclelinux:8-slim` |
| cgw | `ol8/instantclient/32bit:19.31` |
| ses | `ol8/instantclient/32bit:19.31` |
| sai | `oraclelinux:8-slim` |
| mde | `ol8/instantclient/32bit:19.31` |

CGW, SES, and MDE build on top of the instantclient image because they run the Siebel Server and Gateway binaries, which require 32-bit Oracle client libraries for database connectivity.

SAI (Application Interface) is pure Java/Tomcat — it proxies requests to the Siebel Server but has no direct Oracle client dependency — so it builds directly from Oracle Linux slim. Because the slim image only has `microdnf`, SAI's Dockerfile includes an extra step to install the full `dnf` before the main package install.

## Password encryptions

| Image | PKI password | Admin password |
|---|---|---|
| cgw | yes | no |
| ses | yes | no |
| sai | yes | yes (SADMIN) |
| mde | yes | yes (SADMIN) |

SAI and MDE embed both an encrypted PKI password (for the SSL keystore) and a separately encrypted SADMIN password in their response files. CGW and SES only need the PKI password.

## Response file configuration

The installer response file controls what Siebel components get installed:

| Image | `ENTERPRISE_CONTAINER_CONFIGURATION` | `AI_CONTAINER_CONFIGURATION` |
|---|---|---|
| cgw | true | false |
| ses | true | false |
| sai | false | true |
| mde | true | true |

MDE installs all three subsystems in one image, which is why its response file is the largest and requires the full set of port arguments from both the enterprise and AI sections.

## Ports configured in response file

| Image | Ports |
|---|---|
| cgw | Gateway HTTP/Shutdown/Redirect (4091, 4092, 4090) |
| ses | Server HTTP/Shutdown/Redirect (5090, 5092, 5091) |
| sai | AI HTTP/Shutdown/Redirect (6090, 6092, 6091) |
| mde | All of the above combined |

## Exposed ports

| Image | Exposed |
|---|---|
| cgw | none |
| ses | none |
| sai | 6091 |
| mde | 6091, 2322 |

Port 6091 is the AI redirect port (mapped to 443 for SAI, 4443 for MDE on the host). Port 2322 is the Siebel Gateway registry port, which MDE exposes because it hosts its own gateway.

## Runtime scripts

| Image | Scripts |
|---|---|
| cgw | start/stop gateway, start/stop gateway tomcat |
| ses | start/stop siebel server, start/stop server tomcat |
| sai | start/stop SAI tomcat only |
| mde | start/stop gateway, start/stop siebel server, start/stop AI internal, start/stop AI external, start srvrmgr |

MDE has 9 scripts vs 4 for the others because it manages all three subsystems independently.

## Additional build ARGs (MDE only)

MDE's `start_srvrmgr.sh` is generated at build time with deployment-specific values:

| ARG | Purpose |
|---|---|
| `GW_TLS_PORT` | TLS port the gateway listens on (default 2320) |
| `SIEBEL_ENTERPRISE` | Enterprise name (default dev01) |
| `MDE_HOSTNAME` | Container hostname used to connect to the gateway (default dev01mde01) |

## chmod scope

- CGW, SES, SAI → `chmod -R 755 /siebel/<component>`
- MDE → `chmod -R 755 /siebel` (entire tree, since MDE owns all three component directories)
