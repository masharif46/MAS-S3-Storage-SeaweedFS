# MAS S3 Storage SeaweedFS

Single-node SeaweedFS S3-compatible object storage deployed with Docker, persistent host storage, and Nginx routing. Intended for CloudNativePG backups and other applications that need an S3-compatible endpoint.

Recommended GitHub repository name: `mas-storage-seaweedfs`

Recommended GitHub description:

> Single-node SeaweedFS S3 storage with Docker, persistent host storage, Nginx routing, and safe install/uninstall scripts.

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
chmod +x backup-seaweedfs.sh restore-seaweedfs.sh
sudo ./install-seaweedfs.sh
sudo ./install-nginx.sh
```

The installer creates `.env` with a randomly generated S3 secret. The storage directory is created automatically and assigned to the `seaweed` UID/GID detected from the pinned image; the host login user’s UID does not need to match.

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

For applications that support these application-specific variables:

```bash
export OBJECT_STORAGE_BACKEND=seaweedfs
export SEAWEEDFS_S3_ENDPOINT=http://mas-storage-seaweedfs.com
export SEAWEEDFS_S3_REGION=us-east-1
export SEAWEEDFS_ACCESS_KEY="$(sed -n 's/^S3_ACCESS_KEY=//p' .env)"
export SEAWEEDFS_SECRET_KEY="$(sed -n 's/^S3_SECRET_KEY=//p' .env)"
```

`OBJECT_STORAGE_BACKEND` and `SEAWEEDFS_*` are application-specific variables, not universal SeaweedFS settings. Never commit `.env` or expose the secret in logs.

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

## Operations and troubleshooting

```bash
docker logs -f mas-storage-seaweedfs
docker ps -a --filter name=mas-storage-seaweedfs
docker port mas-storage-seaweedfs
sudo du -sh /opt/mas-storage-seaweedfs
df -h /opt/mas-storage-seaweedfs
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker run --rm --network k3d-gitlab-k8s curlimages/curl:latest  curl -v http://<SEAWEEDFS_IP>:8333
docker run --rm --network k3d-gitlab-k8s curlimages/curl:latest curl -v http://172.20.0.6:8333
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
docker inspect mas-storage-seaweedfs --format '{{with index .NetworkSettings.Networks "k3d-gitlab-k8s"}}{{.IPAddress}}{{end}}'
docker run --rm --network k3d-gitlab-k8s curlimages/curl:latest curl -v http://172.20.0.6:8333

```

The installer prints diagnostics automatically if the S3 endpoint does not become ready. It also detects crash-looping containers and recreates them when appropriate.

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



## Security and availability

- S3 and Admin bind to localhost by default; Nginx provides hostname access.
- Add TLS and firewall restrictions before remote exposure.
- Credentials are stored in `.env`, which is ignored by Git.
- This is a single-node deployment and does not provide host-failure protection, replication, immutable backups, or encryption in transit by itself.
