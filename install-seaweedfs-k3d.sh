#!/usr/bin/env bash

set -Eeuo pipefail

# SeaweedFS single-node S3 deployment.
# Configuration is loaded from .env and the S3 identity file is generated
# outside the container with restrictive permissions.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly CONFIG_DIR="${SCRIPT_DIR}/.seaweedfs"
readonly S3_CONFIG_FILE="${CONFIG_DIR}/s3.json"
readonly CONTAINER_NAME="mas-storage-seaweedfs"
readonly MANAGED_LABEL="com.example.seaweedfs.managed"

SEAWEEDFS_IMAGE="chrislusf/seaweedfs:4.47"
SEAWEEDFS_DATA_DIR="/opt/mas-storage-seaweedfs"
SEAWEEDFS_UID=""
SEAWEEDFS_GID=""
S3_BIND_ADDRESS="127.0.0.1"
S3_PORT="28333"
MASTER_BIND_ADDRESS="127.0.0.1"
MASTER_PORT="29333"
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_BUCKET="cnpg-backups"

log() { printf '[INFO] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

on_error() {
    printf '[ERROR] Installation failed near line %s.\n' "$1" >&2
    printf '        Inspect logs with: docker logs %s\n' "$CONTAINER_NAME" >&2
}
trap 'on_error "$LINENO"' ERR

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

managed_container_conflict() {
    printf '\n============================================================\n' >&2
    printf ' SeaweedFS installation stopped: container name conflict\n' >&2
    printf '============================================================\n' >&2
    printf 'A container named "%s" already exists, but it was not created by this installer.\n' "${CONTAINER_NAME}" >&2
    printf 'For safety, the installer will not remove or replace it automatically.\n\n' >&2
    printf 'Recommended recovery:\n' >&2
    printf '  1. sudo ./uninstall-seaweedfs.sh\n' >&2
    printf '  2. Type UNINSTALL when prompted\n' >&2
    printf '  3. sudo ./install-seaweedfs.sh\n' >&2
    printf '  4. sudo ./install-nginx.sh\n\n' >&2
    printf 'Target Nginx URLs after recovery:\n' >&2
    printf '  S3:    http://mas-storage-seaweedfs.com\n' >&2
    printf '  Admin: http://admin.mas-storage-seaweedfs.com\n\n' >&2
    printf 'The uninstall script preserves the data directory "%s" by default.\n' "${SEAWEEDFS_DATA_DIR}" >&2
    printf 'Inspect the existing container first with:\n' >&2
    printf '  sudo docker ps -a --filter name=%s\n' "${CONTAINER_NAME}" >&2
    exit 1
}

random_value() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

create_env_file() {
    umask 077
    cat >"${ENV_FILE}" <<EOF
# Generated automatically. Keep this file private and out of source control.
SEAWEEDFS_IMAGE=chrislusf/seaweedfs:4.47
SEAWEEDFS_DATA_DIR=/opt/mas-storage-seaweedfs
S3_BIND_ADDRESS=127.0.0.1
S3_PORT=28333
MASTER_BIND_ADDRESS=127.0.0.1
MASTER_PORT=29333
S3_ACCESS_KEY=cnpg-admin
S3_SECRET_KEY=$(random_value)
S3_BUCKET=cnpg-backups
EOF
    chmod 600 "${ENV_FILE}"
    log "Created ${ENV_FILE} with a randomly generated secret."
}

load_config() {
    [[ -f "${ENV_FILE}" ]] || create_env_file
    # shellcheck disable=SC1090
    source "${ENV_FILE}"

    [[ "${S3_SECRET_KEY:-}" =~ ^[A-Za-z0-9._~+/=-]{32,}$ ]] || \
        die "S3_SECRET_KEY must be at least 32 safe characters in ${ENV_FILE}"
    [[ "${S3_ACCESS_KEY:-}" =~ ^[A-Za-z0-9._-]{3,128}$ ]] || \
        die "S3_ACCESS_KEY contains invalid characters"
    [[ "${S3_BUCKET:-}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || \
        die "S3_BUCKET must be a valid S3-style bucket name"
    [[ "${S3_PORT:-}" =~ ^[0-9]+$ && "${S3_PORT}" -ge 1 && "${S3_PORT}" -le 65535 ]] || \
        die "S3_PORT must be between 1 and 65535"
    [[ "${MASTER_PORT:-}" =~ ^[0-9]+$ && "${MASTER_PORT}" -ge 1 && "${MASTER_PORT}" -le 65535 ]] || \
        die "MASTER_PORT must be between 1 and 65535"
    [[ "${SEAWEEDFS_DATA_DIR:-}" == /* && "${SEAWEEDFS_DATA_DIR}" != *[[:space:]]* ]] || \
        die "SEAWEEDFS_DATA_DIR must be an absolute path without whitespace"
    [[ "${S3_BIND_ADDRESS:-}" != *[[:space:]]* && "${MASTER_BIND_ADDRESS:-}" != *[[:space:]]* ]] || \
        die "Bind addresses must not contain whitespace"
}

write_s3_config() {
    mkdir -p "${CONFIG_DIR}"
    # SeaweedFS drops privileges before reading this bind-mounted file. The
    # credentials are still kept outside the image, while the runtime config
    # must be traversable/readable by the container's non-root user.
    chmod 755 "${CONFIG_DIR}"
    umask 077
    cat >"${S3_CONFIG_FILE}" <<EOF
{
  "identities": [
    {
      "name": "${S3_ACCESS_KEY}",
      "credentials": [
        {
          "accessKey": "${S3_ACCESS_KEY}",
          "secretKey": "${S3_SECRET_KEY}"
        }
      ],
      "actions": ["Read", "List", "Tagging", "Write", "Admin"]
    }
  ]
}
EOF
    chmod 644 "${S3_CONFIG_FILE}"
}

restore_sudo_user_ownership() {
    if [[ "${EUID}" -eq 0 && -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
        chown "${SUDO_UID}:${SUDO_GID}" "${ENV_FILE}" "${CONFIG_DIR}" "${S3_CONFIG_FILE}"
    fi
}

prepare_data_dir() {
    mkdir -p "${SEAWEEDFS_DATA_DIR}"
    # The image may use a different UID/GID across releases. Detect it from
    # the pinned image instead of assuming it matches the host login user.
    SEAWEEDFS_UID="$(docker run --rm --entrypoint /bin/sh "${SEAWEEDFS_IMAGE}" -c 'id -u seaweed')"
    SEAWEEDFS_GID="$(docker run --rm --entrypoint /bin/sh "${SEAWEEDFS_IMAGE}" -c 'id -g seaweed')"
    [[ "${SEAWEEDFS_UID}" =~ ^[0-9]+$ && "${SEAWEEDFS_GID}" =~ ^[0-9]+$ ]] || \
        die "Could not determine the seaweed user UID/GID from ${SEAWEEDFS_IMAGE}"
    log "Preparing ${SEAWEEDFS_DATA_DIR} for container user seaweed UID/GID ${SEAWEEDFS_UID}:${SEAWEEDFS_GID} (host login UID is independent)"
    # This directory is dedicated to this service, so make ownership explicit
    # for a bind mount and for data migrated from a Docker volume.
    chown -R "${SEAWEEDFS_UID}:${SEAWEEDFS_GID}" "${SEAWEEDFS_DATA_DIR}"
    chmod 750 "${SEAWEEDFS_DATA_DIR}"
}

remove_managed_container() {
    if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        return
    fi

    local managed
    managed="$(docker inspect -f '{{ index .Config.Labels "${MANAGED_LABEL}" }}' "${CONTAINER_NAME}")"
    [[ "${managed}" == "true" ]] || managed_container_conflict
    log "Replacing the existing managed container (the data directory is preserved)."
    docker rm -f "${CONTAINER_NAME}" >/dev/null
}

reuse_running_container() {
    if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        return 1
    fi

    local managed running restart_count
    managed="$(docker inspect -f '{{ index .Config.Labels "${MANAGED_LABEL}" }}' "${CONTAINER_NAME}")"
    [[ "${managed}" == "true" ]] || managed_container_conflict

    running="$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}")"
    [[ "${running}" == "true" ]] || return 1
    restart_count="$(docker inspect -f '{{.RestartCount}}' "${CONTAINER_NAME}")"
    [[ "${restart_count}" == "0" ]] || return 1

    log "Container ${CONTAINER_NAME} is already running; skipping image pull and restart."
    wait_for_s3
    printf '\nSeaweedFS is already ready.\n'
    printf 'S3 endpoint:    http://%s:%s\n' "${S3_BIND_ADDRESS}" "${S3_PORT}"
    printf 'Admin endpoint: http://%s:%s\n' "${MASTER_BIND_ADDRESS}" "${MASTER_PORT}"
    printf 'Nginx S3 URL:   http://mas-storage-seaweedfs.com\n'
    printf 'Nginx Admin URL: http://admin.mas-storage-seaweedfs.com\n'
    show_diagnostics
    exit 0
}

wait_for_s3() {
    local url="http://127.0.0.1:${S3_PORT}"
    local status
    for _ in {1..60}; do
        status="$(curl --silent --output /dev/null --write-out '%{http_code}' "${url}" || true)"
        case "${status}" in
            2*|3*|403) return 0 ;;
        esac
        sleep 1
    done
    show_diagnostics >&2
    die "S3 endpoint did not become ready: ${url}"
}

show_diagnostics() {
    printf '\n--- SeaweedFS diagnostics ---\n'
    printf 'Container status:\n'
    docker ps -a --filter "name=^/${CONTAINER_NAME}$" || true
    printf '\nPublished ports:\n'
    docker port "${CONTAINER_NAME}" || true
    printf '\nRecent logs:\n'
    docker logs --tail 100 "${CONTAINER_NAME}" || true
    printf '\nVolume details:\n'
    printf '\nData directory:\n'
    du -sh "${SEAWEEDFS_DATA_DIR}" 2>/dev/null || true
    df -h "${SEAWEEDFS_DATA_DIR}" 2>/dev/null || true
    printf '\nDocker disk usage:\n'
    docker system df -v || true
    printf '\nUseful storage commands:\n'
    printf '  docker exec %s sh -c '\''du -sh /data; df -h /data'\''\n' "${CONTAINER_NAME}"
    printf '  docker logs -f %s\n' "${CONTAINER_NAME}"
}

main() {
    require_command docker
    require_command curl
    docker info >/dev/null 2>&1 || die "Docker daemon is not running"

    load_config
    write_s3_config
    restore_sudo_user_ownership
    reuse_running_container || true

    log "Pulling pinned image ${SEAWEEDFS_IMAGE}"
    docker pull "${SEAWEEDFS_IMAGE}"

    prepare_data_dir
    remove_managed_container
    mkdir -p "${SEAWEEDFS_DATA_DIR}"

    log "Starting SeaweedFS"
    docker run --detach \
        --name "${CONTAINER_NAME}" \
        --restart unless-stopped \
        --label "${MANAGED_LABEL}=true" \
		--network k3d-flowvaro-dev-lab \
        --network k3d-gitlab-k8s \
        --publish "${S3_BIND_ADDRESS}:${S3_PORT}:8333" \
        --publish "${MASTER_BIND_ADDRESS}:${MASTER_PORT}:9333" \
        --volume "${SEAWEEDFS_DATA_DIR}:/data" \
        --volume "${S3_CONFIG_FILE}:/etc/seaweedfs/s3.json:ro" \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,size=64m \
        --cap-drop ALL \
        --cap-add CHOWN \
        --cap-add SETGID \
        --cap-add SETUID \
        --security-opt no-new-privileges:true \
        "${SEAWEEDFS_IMAGE}" \
        server -dir=/data -s3 -s3.config=/etc/seaweedfs/s3.json -master.volumePreallocate=false -ip.bind=0.0.0.0

    wait_for_s3

    printf '\nSeaweedFS is ready.\n'
    printf 'S3 endpoint:       http://%s:%s\n' "${S3_BIND_ADDRESS}" "${S3_PORT}"
    printf 'Admin endpoint:    http://%s:%s\n' "${MASTER_BIND_ADDRESS}" "${MASTER_PORT}"
    printf 'Nginx S3 URL:      http://mas-storage-seaweedfs.com\n'
    printf 'Nginx Admin URL:   http://admin.mas-storage-seaweedfs.com\n'
    printf 'Configured bucket: %s (create it with the AWS CLI; see README.md)\n' "${S3_BUCKET}"
    printf '\nStorage usage:\n'
    docker exec "${CONTAINER_NAME}" sh -c 'du -sh /data; df -h /data' || true
    printf '\nTroubleshooting:\n'
    printf '  docker ps -a --filter name=%s\n' "${CONTAINER_NAME}"
    printf '  docker logs -f %s\n' "${CONTAINER_NAME}"
    printf '  docker port %s\n' "${CONTAINER_NAME}"
    printf '  sudo du -sh %s\n' "${SEAWEEDFS_DATA_DIR}"
    printf '  df -h %s\n' "${SEAWEEDFS_DATA_DIR}"
    printf '  docker system df -v\n'
    printf '  docker exec %s sh -c '\''du -sh /data; df -h /data'\''\n' "${CONTAINER_NAME}"
    printf '\nUseful commands:\n'
    printf '  docker logs -f %s\n' "${CONTAINER_NAME}"
    printf '  docker restart %s\n' "${CONTAINER_NAME}"
    printf '  ./install-seaweedfs.sh\n'
}

main "$@"
