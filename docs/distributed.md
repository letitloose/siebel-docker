# Distributed (4-container) setup

> **Status: not yet built out.**
> The Dockerfiles and `docker-compose.distributed.yml` exist, but the bootstrap script has not been adapted for this topology. This document describes the intended architecture and what still needs to be done.

## Architecture

In the distributed setup each Siebel component runs in its own container, matching the production deployment model:

| Container | Image | Role |
|---|---|---|
| `${CGW_HOSTNAME}` | `ol8/siebel/cgw-base` | Cloud Gateway + Zookeeper registry |
| `${SES_HOSTNAME}` | `ol8/siebel/ses-base` | Siebel Enterprise Server |
| `${SAI_HOSTNAME}` | `ol8/siebel/sai-base` | Application Interface (Tomcat) |
| `${DB_HOST}` | Oracle 19c | Database |

The MDE container used in the single-machine setup is the three Siebel components (`cgw` + `ses` + `sai`) combined into one image for simplicity. In the distributed setup you build and run them separately.

## Build

```bash
# 1. Build the Instant Client base (required by cgw and ses)
docker compose -f docker-compose.distributed.yml build instantclient

# 2. Build the three Siebel component images
docker compose -f docker-compose.distributed.yml build cgw ses sai
```

## Start

```bash
docker compose -f docker-compose.distributed.yml up -d oracle19c
# wait for DB to be ready, then:
docker compose -f docker-compose.distributed.yml up -d cgw ses sai
```

Port mapping in the distributed setup:

| Service | Host port | Container port |
|---|---|---|
| SAI (Application Interface) | `443` | `${AI_REDIRECT_PORT}` (default 6091) |
| CGW (Zookeeper registry) | `${GW_REGISTRY_PORT}` (default 2322) | same |

## Bootstrap

The `scripts/bootstrap-mde.sh` / `bootstrap-mde.ps1` scripts are written for the single-machine MDE topology. Adapting them for the distributed setup requires:

1. Starting each container's internal Tomcat separately (`docker compose exec cgw bash ./start_cgw.sh`, etc.)
2. Hitting the Cloud Gateway REST API on the CGW container rather than MDE (i.e. `https://localhost:<CGW_REDIRECT_PORT>/siebel/v1.0/...`)
3. Deploying the SES and SAI containers to the separate CGW host

This is the next phase of work on this project.

## Web assets

In the distributed setup the webroot bind mount goes on the SAI container, not MDE. This is already wired in `docker-compose.distributed.yml`:

```yaml
sai:
  volumes:
    - ./data/webroot:/siebel/sai/applicationcontainer_external/siebelwebroot
```

Confirm the exact Tomcat context path when the SAI image build is verified.
