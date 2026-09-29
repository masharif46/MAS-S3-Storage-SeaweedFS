#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly IDENTITIES_FILE="${SCRIPT_DIR}/.seaweedfs/identities.conf"
readonly ENV_FILE="${SCRIPT_DIR}/.env"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    printf 'Usage: sudo ./grant-s3-identity-buckets.sh IDENTITY --bucket NAME [--bucket NAME ...]\n'
    exit 0
fi

identity_name="${1:-}"
shift || true
declare -a bucket_names=()

usage() { printf 'Usage: sudo ./grant-s3-identity-buckets.sh IDENTITY --bucket NAME [--bucket NAME ...]\n'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bucket|-b) [[ $# -ge 2 ]] || { printf '[ERROR] --bucket requires a value.\n' >&2; exit 1; }; bucket_names+=("$2"); shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) printf '[ERROR] Unknown argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ "${identity_name}" =~ ^[A-Za-z0-9._-]+$ ]] || { usage >&2; exit 1; }
[[ ${#bucket_names[@]} -gt 0 ]] || { printf '[ERROR] At least one bucket is required.\n' >&2; exit 1; }
[[ -f "${IDENTITIES_FILE}" ]] || { printf '[ERROR] Missing %s.\n' "${IDENTITIES_FILE}" >&2; exit 1; }
[[ -f "${ENV_FILE}" ]] || { printf '[ERROR] Missing %s. Run install-seaweedfs.sh first.\n' "${ENV_FILE}" >&2; exit 1; }

# shellcheck disable=SC1090
source "${ENV_FILE}"

for bucket_name in "${bucket_names[@]}"; do
    [[ "${bucket_name}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || { printf '[ERROR] Invalid bucket name: %s\n' "${bucket_name}" >&2; exit 1; }
done

command -v aws >/dev/null 2>&1 || {
    printf '[ERROR] AWS CLI is required to validate the requested buckets.\n' >&2
    printf '        Install AWS CLI, create the buckets as administrator, then retry.\n' >&2
    exit 1
}
admin_endpoint="http://127.0.0.1:${S3_PORT:-28333}"
for bucket_name in "${bucket_names[@]}"; do
    if ! AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY}" \
        AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
        AWS_DEFAULT_REGION='us-east-1' \
        aws --endpoint-url "${admin_endpoint}" s3api head-bucket --bucket "${bucket_name}" >/dev/null 2>&1; then
        printf '[ERROR] Requested bucket does not exist: %s\n' "${bucket_name}" >&2
        printf '        Create this exact name with the administrator identity first:\n' >&2
        printf '  aws --endpoint-url %s s3 mb s3://%s\n' "${admin_endpoint}" "${bucket_name}" >&2
        exit 1
    fi
done

record="$(awk -F'|' -v name="${identity_name}" '$1 == name { print; exit }' "${IDENTITIES_FILE}")"
[[ -n "${record}" ]] || { printf '[ERROR] Identity does not exist: %s\n' "${identity_name}" >&2; exit 1; }
IFS='|' read -r name access_key secret_key actions <<< "${record}"
[[ "${actions}" != *Admin* ]] || { printf '[ERROR] Refusing to modify an Admin identity.\n' >&2; exit 1; }

new_actions=""
for bucket_name in "${bucket_names[@]}"; do
    [[ -z "${new_actions}" ]] || new_actions+=','
    new_actions+="Read:${bucket_name},List:${bucket_name},Tagging:${bucket_name},Write:${bucket_name}"
done

backup_file="${IDENTITIES_FILE}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "${IDENTITIES_FILE}" "${backup_file}"
tmp_file="$(mktemp "${IDENTITIES_FILE}.tmp.XXXXXX")"
trap 'rm -f -- "${tmp_file}"' EXIT
awk -F'|' -v name="${identity_name}" -v replacement="${name}|${access_key}|${secret_key}|${new_actions}" '$1 == name { print replacement; next } { print }' "${IDENTITIES_FILE}" >"${tmp_file}"
mv -- "${tmp_file}" "${IDENTITIES_FILE}"
trap - EXIT

printf '[INFO] Granted bucket-scoped access to %s for: %s\n' "${identity_name}" "${bucket_names[*]}"
printf '[INFO] Identity backup: %s\n' "${backup_file}"
"${SCRIPT_DIR}/install-seaweedfs.sh"
printf '[INFO] Configuration applied. Bucket creation remains admin-only.\n'
