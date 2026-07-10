# OCI Setup Guide

Running siebel-docker on an OCI compute instance, with large files (dump, software, webroot) on a Block Volume so they never need to be re-uploaded when you create a new instance.

---

## Overview

```
Block Volume (/mnt/siebel)
├── data/
│   ├── dumps/        ← DB dump files (~7 GB)
│   └── webroot/      ← Siebel web assets
└── software/
    ├── instantclient/ ← Oracle RPMs
    └── Siebel_Enterprise_Server/ ← Installer
```

The Block Volume holds only the large static files. The Oracle data volume (`oracle_data`) lives on the instance's local boot volume and is rebuilt from the dump on first run.

---

## Step 1 — Create the Block Volumes

You need two block volumes. Create them both before creating the instance — they must be in the same Availability Domain as the instance.

### Shared data volume (dumps, software, webroot)

1. **Menu → Storage → Block Storage → Block Volumes → Create Block Volume**
2. Name: `siebel-shared-data`
3. **Availability Domain**: note which AD you choose
4. **Size**: 100 GB (dumps ~7 GB + software ~15 GB + webroot + headroom)
5. **Performance**: Balanced — these are large sequential reads, random IOPS don't matter here
6. Click **Create**

### Oracle data volume (datafiles)

1. **Create Block Volume** again
2. Name: `siebel-oracle-data`
3. **Same Availability Domain** as above
4. **Size**: 100 GB
5. **Performance**: Higher Performance — Oracle does heavy random I/O during import and at runtime; the extra IOPS directly reduces import time and improves query speed
6. Click **Create**

---

## Step 2 — Create the Compute Instance

1. **Menu → Compute → Instances → Create Instance**
2. **Image**: Oracle Linux 8 (recommended — same OS as the containers)
3. **Shape**: VM.Standard.E4.Flex — set at least **4 OCPUs and 16 GB RAM**
   - Oracle alone needs ~4 GB, Siebel Server needs another 4–8 GB
4. **Availability Domain**: must match the Block Volume from Step 1
5. **Networking**: choose or create a VCN and public subnet
6. **SSH keys**: add your public key
7. **Boot volume**: increase to at least **100 GB** (Docker images and the Oracle data volume live here)
8. Click **Create**

Wait for the instance status to show **Running**, then note its public IP.

---

## Step 3 — Open port 4443

Siebel's Application Interface is published on port 4443. You need to allow inbound traffic to it.

1. On the instance page click the **Networking** tab
2. Click the **Subnet** link
3. Click the **Security** tab — you may see multiple security lists; click **Default Security List for \<vcn-name\>** (not `SecListBastion` or similar, which are for bastion SSH access only)
4. Click **Add Ingress Rules**
5. Source CIDR: `0.0.0.0/0` (or restrict to your IP), Protocol: TCP, Destination Port: `4443`
6. Click **Add Ingress Rules** to save

---

## Step 4 — Attach Both Block Volumes to the Instance

Attach each volume separately:

1. On the instance page click the **Storage** tab
2. Click **Attach block volume**
3. Select `siebel-shared-data`, **Paravirtualized**, Read/Write → **Attach**
4. Repeat for `siebel-oracle-data`

Both will appear as new block devices (e.g. `/dev/sdb` and `/dev/sdc`). Use `lsblk` after attaching to confirm which is which — the order they appear matches the order you attached them.

---

## Step 5 — SSH in and mount the Block Volumes

```bash
ssh -i ~/.ssh/your_private_key opc@<instance-public-ip>
```

Check which devices appeared:

```bash
lsblk
```

You should see two new unpartitioned disks — typically `/dev/sdb` (shared data) and `/dev/sdc` (Oracle data). Format both (first time only — skip `mkfs` on a reattach):

```bash
sudo mkfs.ext4 /dev/sdb
sudo mkfs.ext4 /dev/sdc
```

Mount them:

```bash
sudo mkdir -p /mnt/siebel /mnt/oracle-data
sudo mount /dev/sdb /mnt/siebel
sudo mount /dev/sdc /mnt/oracle-data
```

Make them survive reboots:

```bash
echo "/dev/sdb /mnt/siebel    ext4 defaults,_netdev,nofail 0 2" | sudo tee -a /etc/fstab
echo "/dev/sdc /mnt/oracle-data ext4 defaults,_netdev,nofail 0 2" | sudo tee -a /etc/fstab
```

Create the directory structure on the shared volume:

```bash
sudo mkdir -p /mnt/siebel/data/{dumps,webroot}
sudo mkdir -p /mnt/siebel/software/{instantclient,Siebel_Enterprise_Server}
sudo chown -R opc:opc /mnt/siebel
```

The Oracle data directory (`/mnt/oracle-data`) is owned by `start.sh` — it sets the correct ownership automatically.

---

## Step 6 — Upload the large files

From your **local machine**, SCP the files up to the mounted volume. This is a one-time operation — the files live on the Block Volume and persist across instance replacements.

```bash
# DB dump(s)
scp -i ~/.ssh/your_private_key /path/to/expdb_dev1_pdb1_2026-02-28.dmp opc@<instance-ip>:/mnt/siebel/data/dumps/

# Web assets (zip — extract on the instance in the next step)
scp -i ~/.ssh/your_private_key /path/to/siebelwebroot_Backup.zip opc@<instance-ip>:/mnt/siebel/data/webroot/

# Oracle Instant Client RPMs
scp -i ~/.ssh/your_private_key oracle-instantclient19.31-*.rpm opc@<instance-ip>:/mnt/siebel/software/instantclient/

# Siebel Enterprise Server installer (directory)
scp -i ~/.ssh/your_private_key -r /path/to/Siebel_Enterprise_Server opc@<instance-ip>:/mnt/siebel/software/
```

Extract the webroot zip on the instance:

```bash
ssh -i ~/.ssh/your_private_key opc@<instance-ip>
cd /mnt/siebel/data/webroot
unzip siebelwebroot_Backup.zip
mv siebelwebroot_Backup/* .
rmdir siebelwebroot_Backup
```

---

## Step 7 — Install Docker and Git

```bash
# Install Git
sudo dnf install -y git

# Add Docker CE repo and install
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Start Docker and enable on boot
sudo systemctl enable --now docker

# Allow opc user to run docker without sudo
sudo usermod -aG docker opc

# Log out and back in for the group change to take effect
exit
```

```bash
ssh -i ~/.ssh/your_private_key opc@<instance-ip>
```

Verify:

```bash
docker run hello-world
```

---

## Step 8 — Log in to Oracle Container Registry

The Oracle 19c database image requires authentication. Log in before pulling:

```bash
docker login container-registry.oracle.com
```

You'll need a free Oracle account at container-registry.oracle.com, and you must have accepted the Oracle Database licence (Database → enterprise → Accept Agreement) — the same one-time step as the local setup.

---

## Step 9 — Clone the repo and configure


```bash
git clone <repo-url> siebel-docker
cd siebel-docker
cp .env.example .env
```

Edit `.env` — at minimum set these values:

```bash
nano .env
```

```
DATA_DIR=/mnt/siebel/data
SOFTWARE_DIR=/mnt/siebel/software
ORACLE_DATA_DIR=/mnt/oracle-data

ORACLE_PWD=...
AI_USER_PWD=...
SIEBEL_ANON_PWD=...
PKI_PWD=...
PKI_DOMAIN=...
DUMP_FILE=expdb_dev1_pdb1_2026-02-28.dmp
MDE_HOSTNAME=...
SIEBEL_ENTERPRISE=...

# Set to the number of OCPUs on your instance to parallelise the schema import
IMPORT_PARALLEL=4
```

---

## Step 10 — Run the start script

```bash
./scripts/start.sh
```

Total time from scratch: ~3 hours (DB creation ~20 min + schema import ~2 hrs + bootstrap ~35 min).

To watch the import progress in another terminal:

```bash
docker compose logs -f oracle19c
```

---

## Reusing the volumes on a new instance

When you want to spin up a fresh instance:

1. `docker compose stop` on the old instance
2. Detach both block volumes from the old instance (they survive instance termination)
3. Create a new instance (Step 2 above), same Availability Domain
4. Attach both volumes to the new instance (Step 4 above)
5. SSH in, mount both (skip `mkfs` — data is already there), clone the repo, configure `.env`, run `start.sh`

The shared volume already has the dump, software, and webroot — nothing to re-upload. The Oracle data volume already has the provisioned database — no re-import needed (~2 hrs saved). `start.sh` detects the existing Oracle datafiles and skips straight to bootstrap.
