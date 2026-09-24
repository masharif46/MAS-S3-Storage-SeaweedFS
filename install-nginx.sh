#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SOURCE_FILE="${SCRIPT_DIR}/nginx/mas-storage-seaweedfs.com.conf"
readonly TARGET_FILE="/etc/nginx/sites-available/mas-storage-seaweedfs.com.conf"
readonly ENABLED_FILE="/etc/nginx/sites-enabled/mas-storage-seaweedfs.com.conf"

[[ "${EUID}" -eq 0 ]] || {
    printf '[ERROR] Run this script as root: sudo ./install-nginx.sh\n' >&2
    exit 1
}

command -v nginx >/dev/null 2>&1 || {
    printf '[ERROR] Nginx is not installed.\n' >&2
    exit 1
}

install -D -m 0644 "${SOURCE_FILE}" "${TARGET_FILE}"
mkdir -p /etc/nginx/sites-enabled
ln -sfn "${TARGET_FILE}" "${ENABLED_FILE}"

nginx -t
systemctl reload nginx

printf 'Nginx configuration installed and reloaded.\n'
printf '  S3:    http://mas-storage-seaweedfs.com\n'
printf '  Admin: http://admin.mas-storage-seaweedfs.com\n'
