# MAS S3 Storage SeaweedFS

Single-node SeaweedFS S3-compatible object storage deployed with Docker, persistent host storage, and Nginx routing. Intended for CloudNativePG backups and other applications that need an S3-compatible endpoint.

Recommended GitHub repository name: `mas-storage-seaweedfs`

Recommended GitHub description:

> Single-node SeaweedFS S3 storage with Docker, persistent host storage, Nginx routing, and safe install/uninstall scripts.

## Table of contents

- [Overview](#mas-s3-storage-seaweedfs)
- [Features](#features)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Installation](#quick-start)
- [Hostname resolution](#local-hostname-resolution)
- [Client configuration](#client-configuration)
- [Storage and capacity](#storage)
- [Operations and troubleshooting](#operations-and-troubleshooting)
- [Backup and restore](#backup)
- [Safe project cleanup](#safe-project-cleanup)
- [Uninstall](#uninstall)
- [Security and availability](#security-and-availability)

## Features

- Pinned SeaweedFS image: `chrislusf/seaweedfs:4.47`
- Persistent storage at `/opt/mas-storage-seaweedfs`
- S3 endpoint on host port `28333`
- Admin endpoint on host port `29333`
- Nginx hostnames for S3 and Admin
- Generated S3 credentials with restrictive `.env` permissions
- Container hardening and readiness checks
- Diagnostic output on startup failures
- Safe uninstall that preserves storage by default
- Cross-server backup and restore scripts
- Multiple named S3 identities for separate projects and environments
- Per-bucket S3 and host storage usage reporting
- Professional deployment smoke test with optional strict Nginx validation

## Architecture

```text
SeaweedFS
│
├── S3 API
│   ├── Direct: http://SERVER_IP:28333
│   └── Nginx:  http://mas-storage-seaweedfs.com
│
├── Web/Admin
│   ├── Direct: http://SERVER_IP:29333
│   └── Nginx:  http://admin.mas-storage-seaweedfs.com
│
├── Container
│   └── mas-storage-seaweedfs
│
└── Persistent data
    └── /opt/mas-storage-seaweedfs
```

Docker maps host ports to SeaweedFS’s internal ports:

```text
28333 → 8333  S3 API
29333 → 9333  Admin/Master
```

## Requirements

- Linux host
- Docker and a running Docker daemon
- `curl`
- Nginx for hostname access
- `sudo` privileges

## Quick start

From the project directory:

```bash
chmod +x install-seaweedfs.sh install-nginx.sh uninstall-seaweedfs.sh
chmod +x backup-seaweedfs.sh restore-seaweedfs.sh add-s3-identity.sh
chmod +x check-storage-usage.sh remove-s3-identity.sh
chmod +x grant-s3-identity-buckets.sh
chmod +x rotate-s3-identity-secret.sh
chmod +x remote-test-object-storage.sh
chmod +x test-seaweedfs.sh
sudo ./install-seaweedfs.sh
sudo ./install-nginx.sh
```

The installer creates `.env` with a randomly generated S3 secret. The storage directory is created automatically and assigned to the `seaweed` UID/GID detected from the pinned image; the host login user’s UID does not need to match.

### Installer selection

Use `install-seaweedfs.sh` for the current deployment. The repository also
contains `install-seaweedfs-k3d.sh` as a legacy environment-specific installer.
Do not use the legacy file for this deployment: it contains hardcoded k3d
network names and does not support the current named-identity configuration.
It is not included in the standard installation flow.

Important `.env` settings include:

```text
SEAWEEDFS_DATA_DIR=/opt/mas-storage-seaweedfs
SEAWEEDFS_S3_PORT=28333
SEAWEEDFS_ADMIN_PORT=29333
S3_ACCESS_KEY=...
S3_SECRET_KEY=...
S3_BUCKET=...
```

Do not commit `.env`. Keep it readable only by administrators and back it up separately from the data archive because it contains credentials.

## Local hostname resolution

On each client that should use the Nginx hostnames, add the Nginx server address to `/etc/hosts`:

```text
SERVER_IP mas-storage-seaweedfs.com admin.mas-storage-seaweedfs.com
```

For Nginx running on the same machine, `SERVER_IP` can be `127.0.0.1`.

Verify resolution:

```bash
getent hosts mas-storage-seaweedfs.com admin.mas-storage-seaweedfs.com
```

## Client configuration

The installer configures credentials but does not silently create a bucket. With AWS CLI:

```bash
export AWS_ACCESS_KEY_ID="$(sed -n 's/^S3_ACCESS_KEY=//p' .env)"
export AWS_SECRET_ACCESS_KEY="$(sed -n 's/^S3_SECRET_KEY=//p' .env)"
aws --endpoint-url http://mas-storage-seaweedfs.com s3 mb s3://cnpg-backups
aws --endpoint-url http://mas-storage-seaweedfs.com s3 ls
```

For local testing without Nginx, use `http://127.0.0.1:28333`.

### Multiple projects and environments

SeaweedFS can expose multiple independent S3 access keys from the same S3 endpoint. Identities are stored privately in `.seaweedfs/identities.conf` using this format:

```text
name|access_key|secret_key|actions
```

The `.seaweedfs` directory contains two different representations of the
credentials:

| File | Purpose |
|---|---|
| `identities.conf` | Source-of-truth identity registry used by the project scripts. |
| `s3.json` | Generated SeaweedFS runtime configuration mounted into the container. |

They should represent the same identities, but they are not the same format.
After creating an identity, regenerate the runtime configuration and restart
the container:

```bash
sudo ./install-seaweedfs.sh
sudo docker restart mas-storage-seaweedfs
```

Verify the active identity names with:

```bash
jq -r '.identities[].name' .seaweedfs/s3.json
cut -d'|' -f1 .seaweedfs/identities.conf | grep -v '^#'
```

If an identity appears in `identities.conf` but not in `s3.json`, it has not
been applied to the running SeaweedFS container. Do not use the legacy
`install-seaweedfs-k3d.sh` installer, because it can regenerate `s3.json`
without the current identity registry.

Create credentials for an application or environment with:

Create the required buckets first using the administrator credentials. Project
identities cannot create or delete buckets; they receive access only to the
existing buckets explicitly listed with `--bucket`.

```bash
sudo ./add-s3-identity.sh laravel-dev --bucket laravel-dev --bucket laravel-assets
sudo ./add-s3-identity.sh laravel-staging --bucket laravel-staging
sudo ./add-s3-identity.sh laravel-prod --bucket laravel-prod
sudo ./install-seaweedfs.sh
sudo docker restart mas-storage-seaweedfs
```

Each command prints the new access key and secret once. Store them in the corresponding application secret manager. Named identities receive bucket-scoped `Read`, `List`, `Tagging`, and `Write` permissions only for the buckets supplied with `--bucket`; the original `default` identity retains `Admin` permission. Use separate identities per environment so credentials can be rotated or revoked independently.

### Complete application example

The following example creates the buckets with the administrator credential,
then creates one Laravel development identity with access to those buckets:

```bash
# 1. Use the administrator credentials to create buckets.
export AWS_ACCESS_KEY_ID='cnpg-admin'
export AWS_SECRET_ACCESS_KEY='THE_ADMIN_SECRET'
export AWS_DEFAULT_REGION='us-east-1'
export S3_ENDPOINT='http://mas-storage-seaweedfs.com'

aws --endpoint-url "$S3_ENDPOINT" s3 mb s3://laravel-dev
aws --endpoint-url "$S3_ENDPOINT" s3 mb s3://laravel-assets
aws --endpoint-url "$S3_ENDPOINT" s3 mb s3://laravel-backups

# 2. Create the identity on the SeaweedFS server with existing buckets.
sudo ./add-s3-identity.sh laravel-dev \
  --bucket laravel-dev \
  --bucket laravel-assets \
  --bucket laravel-backups

# 3. Apply the generated configuration.
sudo ./install-seaweedfs.sh
sudo docker restart mas-storage-seaweedfs
```

The command prints values similar to these once:

```text
Identity:    laravel-dev
Access key:  mas-laravel-dev
Secret key:  <generated-secret>
```

Copy the secret directly into the application secret manager. Do not commit it
to Git, place it in the README, or send it through an unencrypted message.

On the client or application host, replace the administrator credentials with
the new project credentials:

```bash
export AWS_ACCESS_KEY_ID='mas-laravel-dev'
export AWS_SECRET_ACCESS_KEY='THE_GENERATED_SECRET'
export AWS_DEFAULT_REGION='us-east-1'
export S3_ENDPOINT='http://mas-storage-seaweedfs.com'
```

Verify the credentials and buckets:

```bash
aws --endpoint-url "$S3_ENDPOINT" s3 ls
aws --endpoint-url "$S3_ENDPOINT" s3 ls s3://laravel-dev
```

Check all buckets used by this identity from the SeaweedFS project directory:

```bash
sudo ./check-storage-usage.sh \
  --identity laravel-dev \
  --bucket laravel-dev \
  --bucket laravel-assets \
  --bucket laravel-backups
```

Use the same pattern for `laravel-staging` and `laravel-prod`, but keep their
credentials and application secrets separate. Creating an identity does not
automatically create buckets.

To change the bucket access for an existing non-admin identity:

```bash
sudo ./grant-s3-identity-buckets.sh flowvaro-dev \
  --bucket flowvaro-dev \
  --bucket flowvaro-assets
```

This replaces the identity’s permissions with bucket-scoped `Read`, `List`,
`Tagging`, and `Write` actions. It never grants `Admin`, `CreateBucket`, or
bucket-delete access. The command creates a backup of `identities.conf` and
restarts SeaweedFS after applying the configuration.

To rotate only an existing non-admin identity’s secret key while keeping its
identity name, access key, buckets, and permissions unchanged:

```bash
sudo ./rotate-s3-identity-secret.sh laravel-dev
```

Confirm with:

```text
ROTATE laravel-dev
```

The script prints the new secret once, creates an identity-file backup, and
invalidates the old secret. Update the application secret immediately.

When using a named identity from a client, export that identity’s credentials
(not the default `.env` credentials) before creating or accessing its buckets:

```bash
export AWS_ACCESS_KEY_ID='LARAVEL_DEV_ACCESS_KEY'
export AWS_SECRET_ACCESS_KEY='LARAVEL_DEV_SECRET_KEY'
export AWS_DEFAULT_REGION='us-east-1'
aws --endpoint-url http://mas-storage-seaweedfs.com s3 mb s3://laravel-dev
```

Separate identities improve credential management, but the static identity file does not by itself restrict an identity to one bucket. For strict dev/staging/production isolation, use separate SeaweedFS instances or configure bucket/IAM policies supported by your SeaweedFS deployment.

Check usage for a project bucket with:

```bash
sudo ./check-storage-usage.sh \
  --identity laravel-dev \
  --bucket laravel-dev \
  --bucket laravel-assets

sudo ./check-storage-usage.sh \
  --identity laravel-staging \
  --bucket laravel-staging

sudo ./check-storage-usage.sh \
  --identity laravel-prod \
  --bucket laravel-prod
```

The report shows each bucket’s object count and size, combined S3 usage, and host filesystem usage for `/opt/mas-storage-seaweedfs`. One identity can be used with multiple buckets. The legacy form `sudo ./check-storage-usage.sh IDENTITY BUCKET` remains supported.

For applications that support these application-specific variables:

```bash
export OBJECT_STORAGE_BACKEND=seaweedfs
export SEAWEEDFS_S3_ENDPOINT=http://mas-storage-seaweedfs.com
export SEAWEEDFS_S3_REGION=us-east-1
export SEAWEEDFS_ACCESS_KEY="$(sed -n 's/^S3_ACCESS_KEY=//p' .env)"
export SEAWEEDFS_SECRET_KEY="$(sed -n 's/^S3_SECRET_KEY=//p' .env)"
```

`OBJECT_STORAGE_BACKEND` and `SEAWEEDFS_*` are application-specific variables, not universal SeaweedFS settings. Never commit `.env` or expose the secret in logs.

## Safe project cleanup

Use this workflow when permanently removing an application environment. The
script requires an explicit identity and explicit bucket names; it never
assumes that every bucket accessible by an identity belongs to that project.

First list accessible buckets without changing anything:

```bash
sudo ./remove-s3-identity.sh \
  --identity wordpress-dev \
  --list-buckets
```

Preview the exact deletion set:

```bash
sudo ./remove-s3-identity.sh \
  --identity wordpress-dev \
  --bucket wordpress-assets \
  --bucket wordpress-backup \
  --dry-run
```

After verifying the preview, run the deletion:

```bash
sudo ./remove-s3-identity.sh \
  --identity wordpress-dev \
  --bucket wordpress-assets \
  --bucket wordpress-backup
```

The script deletes all objects in the selected buckets, deletes the buckets,
backs up the identity file, removes the identity, and restarts SeaweedFS. It
requires the exact confirmation `DELETE wordpress-dev`. This operation is
irreversible.

To revoke an identity while preserving all of its buckets, use identity-only
mode:

```bash
sudo ./remove-s3-identity.sh \
  --identity wordpress-dev \
  --identity-only
```

This requires the exact confirmation `REVOKE wordpress-dev`. The identity is
removed from the project registry and the buckets remain untouched.

To remove an identity and every bucket accessible by it, use `--all`. Review
the printed list first and use dry-run before the real deletion:

```bash
sudo ./remove-s3-identity.sh \
  --identity wordpress-dev \
  --all \
  --dry-run
```

When the list is correct, run without `--dry-run`:

```bash
sudo ./remove-s3-identity.sh \
  --identity wordpress-dev \
  --all
```

This requires the exact confirmation `DELETE wordpress-dev`. Do not combine
`--all` with `--bucket`; `--all` deletes every bucket visible to that identity,
not only buckets named with the project prefix.

## Nginx

The file `nginx/mas-storage-seaweedfs.com.conf` configures both hostnames. Install it with:

```bash
sudo ./install-nginx.sh
```

The helper copies the configuration into `/etc/nginx/sites-available`, creates the enabled-site symlink, validates Nginx, and reloads it. The supplied configuration is HTTP-only; add TLS before exposing it outside a trusted network.

## Storage

SeaweedFS stores data only in `/opt/mas-storage-seaweedfs`. This is a dedicated host directory, not a Docker-managed volume, so it remains independent of Docker’s internal storage path. Volume preallocation is disabled and storage grows as objects are written until the filesystem reaches its free-space protection threshold.

The `Volume Size Limit is 1024 MB` message refers to each individual SeaweedFS volume file, not total storage. SeaweedFS creates additional volume files as needed.

Check usage:

```bash
sudo du -sh /opt/mas-storage-seaweedfs
df -h /opt/mas-storage-seaweedfs
```

### Migrating from the legacy Docker volume

New installations use `/opt/mas-storage-seaweedfs`. If an older installation
uses the Docker volume `mas-storage-seaweedfs-data`, copy it before changing
the deployment:

```bash
sudo mkdir -p /opt/mas-storage-seaweedfs
sudo docker run --rm \
  -v mas-storage-seaweedfs-data:/from:ro \
  -v /opt/mas-storage-seaweedfs:/to \
  alpine sh -c 'cp -a /from/. /to/'
sudo du -sh /opt/mas-storage-seaweedfs
```

Stop the old container before copying active data, then run the installer.
Keep the old volume until the migrated deployment has been tested.

## S3 client


```bash
cd /tmp

sudo apt update
sudo apt install -y unzip curl

curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip

unzip -q awscliv2.zip

sudo ./aws/install

aws --version
```


## Remote object-storage test

Run this from another computer with AWS CLI installed. It checks bucket access,
uploads a generated file, downloads it, verifies the SHA-256 checksum, and
deletes the temporary object.

```bash
chmod +x remote-test-object-storage.sh
export AWS_ACCESS_KEY_ID='YOUR_ACCESS_KEY'
export AWS_SECRET_ACCESS_KEY='YOUR_SECRET_KEY'

./remote-test-object-storage.sh \
  --endpoint http://mas-storage-seaweedfs.com \
  --bucket laravel-dev
```

Use `--size-mb 10` for a larger transfer test or `--keep-object` to retain the
temporary object. The script never prints the secret key.

Alternatively, configure credentials on the remote computer with `aws
configure` and run the test with `--profile PROFILE_NAME`. The script also
honors the standard AWS CLI credential provider chain.






## Operations and troubleshooting

```bash
docker logs -f mas-storage-seaweedfs
docker ps -a --filter name=mas-storage-seaweedfs
docker port mas-storage-seaweedfs
sudo du -sh /opt/mas-storage-seaweedfs
df -h /opt/mas-storage-seaweedfs
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
docker inspect mas-storage-seaweedfs
curl -v --connect-timeout 5 http://127.0.0.1:28333/
curl -v --connect-timeout 5 http://127.0.0.1:29333/

```

## Kubernetes connectivity troubleshooting (optional)

The following checks are environment-specific examples for Kubernetes nodes and
pods. Replace node names, namespaces, Docker networks, and IP addresses with
values from your environment. Do not copy the example private IP blindly.

```bash
 # Workstation connectivity does not prove Kubernetes connectivity.
 # Test in this order.

 # 1. From the workstation
 getent hosts mas-storage-seaweedfs.com
 curl -vk --connect-timeout 5 http://mas-storage-seaweedfs.com/
 nc -vz -w5 mas-storage-seaweedfs.com 80

 # 2. From each Kubernetes node

 for node in apps-prod-k8s-1 apps-prod-k8s-2 apps-prod-k8s-3; do
   echo "===== $node ====="
   ssh "$node" 'getent hosts mas-storage-seaweedfs.com; curl -sSvk --connect-timeout 5 http://mas-storage-seaweedfs.com/'
 done

 
  # If workstation works but nodes fail, check:
 
  # Check DNS configuration, routing, firewall rules, and whether the
  # service is reachable on the expected external interface.
 
  # 3. From a Kubernetes pod
 
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
 
  kubectl -n apps-dev-data run network-test \
    --rm -it --restart=Never \
    --image=curlimages/curl:8.10.1 -- \
    curl -vk --connect-timeout 5 \
    http://mas-storage-seaweedfs.com/
 
 # If DNS fails:


 kubectl -n apps-dev-data run dns-test \
   --rm -it --restart=Never \
   --image=busybox:1.36 -- \
   nslookup mas-storage-seaweedfs.com

 # If DNS works but curl fails, inspect:

 kubectl -n apps-dev-data get networkpolicy
 kubectl -n apps-dev-data describe networkpolicy


kubectl -n apps-dev-data run dns-test \
  --image=busybox:1.36 \
  --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"runAsGroup":65532,"seccompProfile":
{"type":"RuntimeDefault"}},"containers":[{"name":"dns-test","image":"busybox:1.36","command":["nslookup","mas-storage-seaweedfs.com"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'



```





The installer prints diagnostics automatically if the S3 endpoint does not become ready. It also detects crash-looping containers and recreates them when appropriate.

Run the deployment smoke test with:

```bash
sudo ./test-seaweedfs.sh
```

Use strict mode when both Nginx hostnames must be available:

```bash
sudo ./test-seaweedfs.sh --strict-nginx
```

The test checks Docker, container state, restart loops, data-directory permissions, direct S3/Admin endpoints, Nginx endpoints, and an authenticated S3 request when AWS CLI and the default identity are available. It never prints credentials.

## Backup

For a consistent archive, use the backup script:

```bash
sudo ./backup-seaweedfs.sh
```

Type `BACKUP` when prompted. The script temporarily stops SeaweedFS, archives `/opt/mas-storage-seaweedfs`, and starts the container again. It does not include `.env`; transfer that file separately over a secure channel because it contains the S3 secret.

To restore on another server:

```bash
sudo ./restore-seaweedfs.sh /path/to/mas-storage-seaweedfs-YYYYMMDDTHHMMSSZ.tar.gz
```

Type `RESTORE` when prompted, securely copy the source `.env` into the project directory, then run:

```bash
sudo ./install-seaweedfs.sh
sudo ./install-nginx.sh
```

The restore script refuses to overwrite a non-empty data directory. Test restoration on a separate host; a backup is not complete until the S3 objects can be read.

## Uninstall

The uninstaller removes the SeaweedFS container and Nginx configuration but preserves storage by default:

```bash
sudo ./uninstall-seaweedfs.sh
```

Type `UNINSTALL` when prompted. Only delete the data after verifying backups:

```bash
sudo rm -rf /opt/mas-storage-seaweedfs
```



## Script reference

| Script | Purpose |
|---|---|
| `install-seaweedfs.sh` | Create or reconcile the SeaweedFS container and configuration. |
| `install-seaweedfs-k3d.sh` | Legacy k3d-specific installer; do not use for the current deployment. |
| `install-nginx.sh` | Install, validate, and reload the Nginx reverse proxy. |
| `uninstall-seaweedfs.sh` | Remove the container and Nginx configuration while preserving data by default. |
| `add-s3-identity.sh` | Create a named project or environment identity. |
| `grant-s3-identity-buckets.sh` | Assign existing buckets to a non-admin identity. |
| `rotate-s3-identity-secret.sh` | Rotate a non-admin identity’s secret without changing its access key or buckets. |
| `check-storage-usage.sh` | Report one identity’s usage across one or more buckets. |
| `remove-s3-identity.sh` | List buckets or safely remove explicitly selected buckets and an identity. |
| `remote-test-object-storage.sh` | Test remote authenticated upload, download, and checksum integrity. |
| `test-seaweedfs.sh` | Run local deployment and endpoint smoke checks. |
| `backup-seaweedfs.sh` | Create a consistent archive of the data directory. |
| `restore-seaweedfs.sh` | Restore an archive to an empty data directory. |

## Security and availability

- Docker-published S3/Admin ports may be reachable on host interfaces; restrict them with a firewall or bind Docker ports to `127.0.0.1` when only Nginx should be public.
- Add HTTPS/TLS and firewall restrictions before remote exposure. Do not send production credentials over plain HTTP on an untrusted network.
- Credentials are stored in `.env`, which is ignored by Git.
- This is a single-node deployment and does not provide host-failure protection, replication, immutable backups, or encryption in transit by itself.

Recommended exposed ports:

```text
80/tcp   Nginx HTTP (redirect to HTTPS when TLS is configured)
443/tcp  Nginx HTTPS
28333/tcp  Direct S3 API only when explicitly required
29333/tcp  Direct Admin API; preferably restricted to administrators
```

## Acknowledgements

This project uses [SeaweedFS](https://github.com/seaweedfs/seaweedfs), an open-source storage system that provides the S3-compatible object-storage service used here. Many thanks to the SeaweedFS maintainers and contributors for their work.
