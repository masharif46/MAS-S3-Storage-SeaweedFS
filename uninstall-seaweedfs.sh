#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CONTAINER_NAME="mas-storage-seaweedfs"
readonly DATA_DIR="/opt/mas-storage-seaweedfs"
readonly IMAGE="chrislusf/seaweedfs:4.47"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly CONFIG_DIR="${SCRIPT_DIR}/.seaweedfs"
readonly NGINX_SITE="/etc/nginx/sites-available/mas-storage-seaweedfs.com.conf"
readonly NGINX_LINK="/etc/nginx/sites-enabled/mas-storage-seaweedfs.com.conf"

purge=false

usage() {
    printf 'Usage: sudo ./uninstall-seaweedfs.sh [--purge]\n'
    printf '\n'
    printf '  --purge  Remove all SeaweedFS data and generated credentials for a true fresh install.\n'
}

case "${1:-}" in
    '') ;;
    --purge)
        [[ $# -eq 1 ]] || { printf '[ERROR] --purge does not accept additional options.\n' >&2; exit 2; }
        purge=true
        ;;
    --help|-h) usage; exit 0 ;;
    *) printf '[ERROR] Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac

printf '\n'
printf '============================================================\n'
printf ' WARNING: SeaweedFS uninstall\n'
printf '============================================================\n'
printf 'This will remove the container: %s\n' "${CONTAINER_NAME}"
printf 'This will remove the Nginx site configuration.\n'
if [[ "${purge}" == true ]]; then
    printf 'This will PERMANENTLY remove all project state:\n'
    printf '  %s\n' "${DATA_DIR}"
    printf '  %s\n' "${ENV_FILE}"
    printf '  %s\n' "${CONFIG_DIR}"
    printf 'This removes all buckets, objects, identities, and generated S3 credentials.\n'
else
    printf 'The dedicated data directory and project credentials will be PRESERVED:\n'
    printf '  %s\n' "${DATA_DIR}"
    printf '  %s\n' "${ENV_FILE}"
    printf '  %s\n' "${CONFIG_DIR}"
fi
printf '\n'
if [[ "${purge}" == true ]]; then
    printf 'To continue, type exactly: PURGE\n'
    expected_confirmation='PURGE'
else
    printf 'To continue, type exactly: UNINSTALL\n'
    expected_confirmation='UNINSTALL'
fi
read -r confirmation
[[ "${confirmation}" == "${expected_confirmation}" ]] || {
    printf 'Cancelled. Nothing was changed.\n'
    exit 0
}

if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    printf '[INFO] Removing container %s...\n' "${CONTAINER_NAME}"
    docker rm -f "${CONTAINER_NAME}" >/dev/null
else
    printf '[INFO] Container %s is not present.\n' "${CONTAINER_NAME}"
fi

if [[ -e "${NGINX_LINK}" || -L "${NGINX_LINK}" ]]; then
    rm -f "${NGINX_LINK}"
    printf '[INFO] Removed Nginx enabled-site link.\n'
fi
if [[ -f "${NGINX_SITE}" ]]; then
    rm -f "${NGINX_SITE}"
    printf '[INFO] Removed Nginx site configuration.\n'
    if command -v nginx >/dev/null 2>&1; then
        nginx -t && systemctl reload nginx
    fi
fi

if [[ "${purge}" == true ]]; then
    rm -rf -- "${DATA_DIR}" "${CONFIG_DIR}" "${ENV_FILE}"
    printf '\n[INFO] Removed data directory, identity registry, runtime S3 configuration, and .env credentials.\n'
    printf '[INFO] The next install will create a new administrator identity and empty storage.\n'
else
    printf '\n[SAFE] Data directory and project credentials preserved.\n'
fi
printf 'The image was also preserved: %s\n' "${IMAGE}"
if [[ "${purge}" == false ]]; then
    printf '\nFor a completely new deployment, use:\n'
    printf '  sudo ./uninstall-seaweedfs.sh --purge\n'
fi
printf '\nSeaweedFS uninstall completed.\n'
