#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly IDENTITIES_FILE="${SCRIPT_DIR}/.seaweedfs/identities.conf"
readonly DEFAULT_DATA_DIR="/opt/mas-storage-seaweedfs"

identity_name=""
s3_endpoint="http://mas-storage-seaweedfs.com"
declare -a bucket_names=()

usage() {
    printf 'Usage: sudo ./check-storage-usage.sh --identity NAME --bucket NAME [--bucket NAME ...] [--endpoint URL]\n'
    printf 'Example: sudo ./check-storage-usage.sh --identity laravel-dev --bucket laravel-dev --bucket laravel-assets\n'
    printf '\nThe same identity may be used for multiple buckets.\n'
    printf 'Legacy format: sudo ./check-storage-usage.sh IDENTITY BUCKET [ENDPOINT]\n'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity|-i) [[ $# -ge 2 ]] || { printf '[ERROR] --identity requires a value.\n' >&2; exit 1; }; identity_name="$2"; shift 2 ;;
        --bucket|-b) [[ $# -ge 2 ]] || { printf '[ERROR] --bucket requires a value.\n' >&2; exit 1; }; bucket_names+=("$2"); shift 2 ;;
        --endpoint|-e) [[ $# -ge 2 ]] || { printf '[ERROR] --endpoint requires a value.\n' >&2; exit 1; }; s3_endpoint="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        --*) printf '[ERROR] Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
        *)
            if [[ -z "${identity_name}" ]]; then identity_name="$1";
            elif [[ ${#bucket_names[@]} -eq 0 ]]; then bucket_names+=("$1");
            elif [[ ${#bucket_names[@]} -eq 1 && "$s3_endpoint" == "http://mas-storage-seaweedfs.com" ]]; then s3_endpoint="$1";
            else printf '[ERROR] Unexpected argument: %s\n' "$1" >&2; usage >&2; exit 1; fi
            shift ;;
    esac
done

if [[ -z "${identity_name}" || ${#bucket_names[@]} -eq 0 ]]; then
    printf '[ERROR] An identity and at least one bucket are required.\n' >&2
    usage >&2
    exit 1
fi
[[ -f "${ENV_FILE}" ]] || { printf '[ERROR] Missing %s. Run install-seaweedfs.sh first.\n' "${ENV_FILE}" >&2; exit 1; }
[[ -f "${IDENTITIES_FILE}" ]] || { printf '[ERROR] Missing %s.\n' "${IDENTITIES_FILE}" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { printf '[ERROR] AWS CLI is required.\n' >&2; exit 1; }

# shellcheck disable=SC1090
source "${ENV_FILE}"
data_dir="${SEAWEEDFS_DATA_DIR:-${DEFAULT_DATA_DIR}}"
identity_record="$(awk -F'|' -v name="${identity_name}" '$1 == name { print; exit }' "${IDENTITIES_FILE}")"
[[ -n "${identity_record}" ]] || { printf '[ERROR] Identity does not exist: %s\n' "${identity_name}" >&2; exit 1; }
IFS='|' read -r _ access_key secret_key _ <<< "${identity_record}"
[[ -n "${access_key}" && -n "${secret_key}" ]] || { printf '[ERROR] Identity record is incomplete: %s\n' "${identity_name}" >&2; exit 1; }
export AWS_ACCESS_KEY_ID="${access_key}" AWS_SECRET_ACCESS_KEY="${secret_key}" AWS_DEFAULT_REGION="${SEAWEEDFS_S3_REGION:-us-east-1}"

printf '\nStorage usage report\n====================\nIdentity:       %s\nS3 endpoint:    %s\nBuckets checked: %d\n\n' "${identity_name}" "${s3_endpoint}" "${#bucket_names[@]}"
total_bytes=0
for bucket_name in "${bucket_names[@]}"; do
    printf 'Bucket: %s\n' "${bucket_name}"
    report="$(aws --endpoint-url "${s3_endpoint}" s3 ls "s3://${bucket_name}" --recursive --summarize 2>&1)" || {
        if grep -qE '(^| )404( |$)|Not Found|NoSuchBucket' <<< "${report}"; then
            printf 'Status:         MISSING\nCreate:         aws --endpoint-url %s s3 mb s3://%s\n\n' "${s3_endpoint}" "${bucket_name}"
        else printf '%s\nStatus:         ERROR\n\n' "${report}" >&2; fi
        continue
    }
    printf '%s\n' "${report}"
    bucket_bytes="$(awk '/Total Size:/ { print $3; exit }' <<< "${report}")"
    [[ "${bucket_bytes}" =~ ^[0-9]+$ ]] && total_bytes=$((total_bytes + bucket_bytes))
    printf '\n'
done
printf 'Combined reported S3 size: %s bytes\n' "${total_bytes}"
if [[ -d "${data_dir}" ]]; then
    printf '\nHost storage\n-------------\n'
    du -sh "${data_dir}" 2>/dev/null || true
    df -h "${data_dir}" 2>/dev/null || true
else printf '\nHost storage: %s does not exist\n' "${data_dir}"; fi
