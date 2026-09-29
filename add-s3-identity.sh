#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly CONFIG_DIR="${SCRIPT_DIR}/.seaweedfs"
readonly IDENTITIES_FILE="${CONFIG_DIR}/identities.conf"

identity_name="${1:-}"
[[ "${identity_name}" =~ ^[A-Za-z0-9._-]+$ ]] || {
    printf 'Usage: sudo ./add-s3-identity.sh <identity-name>\n' >&2
    printf 'Example: sudo ./add-s3-identity.sh laravel-staging\n' >&2
    exit 1
}

[[ -f "${ENV_FILE}" ]] || { printf '[ERROR] Run install-seaweedfs.sh first.\n' >&2; exit 1; }
# shellcheck disable=SC1090
source "${ENV_FILE}"
mkdir -p "${CONFIG_DIR}"
umask 077

if [[ ! -f "${IDENTITIES_FILE}" ]]; then
    printf '# name|access_key|secret_key|actions\n' >"${IDENTITIES_FILE}"
    printf 'default|%s|%s|Read,List,Tagging,Write,Admin\n' "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" >>"${IDENTITIES_FILE}"
fi

if /usr/bin/grep -q "^${identity_name}|" "${IDENTITIES_FILE}"; then
    printf '[ERROR] Identity already exists: %s\n' "${identity_name}" >&2
    exit 1
fi

if command -v openssl >/dev/null 2>&1; then
    secret_key="$(openssl rand -hex 32)"
else
    secret_key="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
fi
access_key="mas-${identity_name}"
printf '%s|%s|%s|Read,List,Tagging,Write\n' "${identity_name}" "${access_key}" "${secret_key}" >>"${IDENTITIES_FILE}"
chmod 600 "${IDENTITIES_FILE}"

printf 'Created identity: %s\n' "${identity_name}"
printf 'Access key:       %s\n' "${access_key}"
printf 'Secret key:       %s\n' "${secret_key}"
printf '\nApply it with:\n  sudo ./install-seaweedfs.sh\n'
printf '  sudo docker restart mas-storage-seaweedfs\n'
