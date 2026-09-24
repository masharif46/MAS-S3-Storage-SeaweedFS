#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly DATA_DIR="/opt/mas-storage-seaweedfs"
readonly CONTAINER_NAME="mas-storage-seaweedfs"
readonly BACKUP_DIR="${1:-${SCRIPT_DIR}/backups}"
readonly ARCHIVE="${BACKUP_DIR}/mas-storage-seaweedfs-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"

[[ "${EUID}" -eq 0 ]] || { printf '[ERROR] Run with sudo.\n' >&2; exit 1; }
[[ -d "${DATA_DIR}" ]] || { printf '[ERROR] Data directory not found: %s\n' "${DATA_DIR}" >&2; exit 1; }

printf 'This creates a consistent archive of %s.\n' "${DATA_DIR}"
printf 'The SeaweedFS container will be stopped temporarily.\n'
printf 'Type BACKUP to continue: '
read -r confirmation
[[ "${confirmation}" == "BACKUP" ]] || { printf 'Cancelled.\n'; exit 0; }

mkdir -p "${BACKUP_DIR}"
container_was_running=false
if docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null | grep -qx true; then
    container_was_running=true
    docker stop "${CONTAINER_NAME}" >/dev/null
fi

restart_container() {
    if [[ "${container_was_running}" == true ]]; then
        docker start "${CONTAINER_NAME}" >/dev/null || true
    fi
}
trap restart_container EXIT

tar --create --gzip --file "${ARCHIVE}" --numeric-owner \
    --directory "${DATA_DIR}" .

printf '\nBackup created:\n  %s\n' "${ARCHIVE}"
du -h "${ARCHIVE}"
printf '\nCopy this archive to the destination server. Transfer .env separately and securely.\n'
