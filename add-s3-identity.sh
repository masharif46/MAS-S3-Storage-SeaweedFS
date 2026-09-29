#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly CONFIG_DIR="${SCRIPT_DIR}/.seaweedfs"
readonly IDENTITIES_FILE="${CONFIG_DIR}/identities.conf"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    printf 'Usage: sudo ./add-s3-identity.sh IDENTITY --bucket NAME [--bucket NAME ...]\n'
    printf 'Example: sudo ./add-s3-identity.sh laravel-dev --bucket laravel-dev --bucket laravel-assets\n'
    exit 0
fi

identity_name="${1:-}"
shift || true
declare -a bucket_names=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bucket|-b)
            [[ $# -ge 2 ]] || { printf '[ERROR] --bucket requires a value.\n' >&2; exit 1; }
            bucket_names+=("$2")
            shift 2
            ;;
        --help|-h)
            printf 'Usage: sudo ./add-s3-identity.sh IDENTITY --bucket NAME [--bucket NAME ...]\n'
            printf 'Example: sudo ./add-s3-identity.sh laravel-dev --bucket laravel-dev --bucket laravel-assets\n'
            exit 0
            ;;
        *) printf '[ERROR] Unknown argument: %s\n' "$1" >&2; exit 1 ;;
    esac
done

[[ "${identity_name}" =~ ^[A-Za-z0-9._-]+$ ]] || {
    printf 'Usage: sudo ./add-s3-identity.sh IDENTITY --bucket NAME [--bucket NAME ...]\n' >&2
    exit 1
}
[[ ${#bucket_names[@]} -gt 0 ]] || {
    printf '[ERROR] At least one existing bucket is required.\n' >&2
    printf 'Only the admin identity may create buckets.\n' >&2
    exit 1
}
for bucket_name in "${bucket_names[@]}"; do
    [[ "${bucket_name}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || {
        printf '[ERROR] Invalid bucket name: %s\n' "${bucket_name}" >&2
        exit 1
    }
done

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
    printf '[INFO] To change its bucket access, use:\n' >&2
    printf '  sudo ./grant-s3-identity-buckets.sh %s --bucket BUCKET [--bucket BUCKET ...]\n' "${identity_name}" >&2
    exit 1
fi

if command -v openssl >/dev/null 2>&1; then
    secret_key="$(openssl rand -hex 32)"
else
    secret_key="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
fi
access_key="mas-${identity_name}"
actions=""
for bucket_name in "${bucket_names[@]}"; do
    [[ -z "${actions}" ]] || actions+=','
    actions+="Read:${bucket_name},List:${bucket_name},Tagging:${bucket_name},Write:${bucket_name}"
done
printf '%s|%s|%s|%s\n' "${identity_name}" "${access_key}" "${secret_key}" "${actions}" >>"${IDENTITIES_FILE}"
chmod 600 "${IDENTITIES_FILE}"

printf 'Created identity: %s\n' "${identity_name}"
printf 'Access key:       %s\n' "${access_key}"
printf 'Secret key:       %s\n' "${secret_key}"
printf '\nApply it with:\n  sudo ./install-seaweedfs.sh\n'
printf '  sudo docker restart mas-storage-seaweedfs\n'
