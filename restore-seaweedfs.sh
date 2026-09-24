#!/usr/bin/env bash

set -Eeuo pipefail

readonly DATA_DIR="/opt/mas-storage-seaweedfs"
readonly CONTAINER_NAME="mas-storage-seaweedfs"
readonly ARCHIVE="${1:-}"

[[ "${EUID}" -eq 0 ]] || { printf '[ERROR] Run with sudo.\n' >&2; exit 1; }
[[ -n "${ARCHIVE}" && -f "${ARCHIVE}" ]] || {
    printf 'Usage: sudo ./restore-seaweedfs.sh /path/to/backup.tar.gz\n' >&2
    exit 1
}

if find "${DATA_DIR}" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    printf '[ERROR] Destination is not empty: %s\n' "${DATA_DIR}" >&2
    printf 'Move existing data aside before restoring. Nothing was changed.\n' >&2
    exit 1
fi

printf 'WARNING: This restores data into %s.\n' "${DATA_DIR}"
printf 'The existing SeaweedFS container will be stopped if present.\n'
printf 'Type RESTORE to continue: '
read -r confirmation
[[ "${confirmation}" == "RESTORE" ]] || { printf 'Cancelled.\n'; exit 0; }

if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    docker rm -f "${CONTAINER_NAME}" >/dev/null
fi

mkdir -p "${DATA_DIR}"
tar --extract --gzip --file "${ARCHIVE}" --numeric-owner --directory "${DATA_DIR}"

printf '\nRestore completed to %s.\n' "${DATA_DIR}"
printf 'Copy the source .env securely, then run:\n'
printf '  sudo ./install-seaweedfs.sh\n'
printf '  sudo ./install-nginx.sh\n'
