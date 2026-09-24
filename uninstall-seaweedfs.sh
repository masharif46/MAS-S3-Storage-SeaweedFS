#!/usr/bin/env bash

set -Eeuo pipefail

readonly CONTAINER_NAME="mas-storage-seaweedfs"
readonly DATA_DIR="/opt/mas-storage-seaweedfs"
readonly IMAGE="chrislusf/seaweedfs:4.47"
readonly NGINX_SITE="/etc/nginx/sites-available/mas-storage-seaweedfs.com.conf"
readonly NGINX_LINK="/etc/nginx/sites-enabled/mas-storage-seaweedfs.com.conf"

printf '\n'
printf '============================================================\n'
printf ' WARNING: SeaweedFS uninstall\n'
printf '============================================================\n'
printf 'This will remove the container: %s\n' "${CONTAINER_NAME}"
printf 'This will remove the Nginx site configuration.\n'
printf 'The dedicated data directory will be PRESERVED by default:\n'
printf '  %s\n' "${DATA_DIR}"
printf '\n'
printf 'To continue, type exactly: UNINSTALL\n'
read -r confirmation
[[ "${confirmation}" == "UNINSTALL" ]] || {
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

printf '\n[SAFE] Data directory preserved: %s\n' "${DATA_DIR}"
printf 'The image was also preserved: %s\n' "${IMAGE}"
printf '\nTo delete the data permanently, run only after confirming you have a backup:\n'
printf '  sudo rm -rf %s\n' "${DATA_DIR}"
printf '\nSeaweedFS uninstall completed.\n'
