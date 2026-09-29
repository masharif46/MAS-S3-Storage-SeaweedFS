#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly IDENTITIES_FILE="${SCRIPT_DIR}/.seaweedfs/identities.conf"
readonly DEFAULT_ENDPOINT="http://mas-storage-seaweedfs.com"

identity_name=""
s3_endpoint="${DEFAULT_ENDPOINT}"
confirm_delete=""
dry_run=0
ignore_missing=0
list_buckets=0
identity_only=0
delete_all=0
declare -a bucket_names=()

usage() {
    printf 'Usage: sudo ./remove-s3-identity.sh --identity NAME [--bucket NAME ... | --all] [--endpoint URL] [--confirm "DELETE NAME"] [--dry-run] [--list-buckets] [--identity-only] [--ignore-missing]\n'
    printf 'Example: sudo ./remove-s3-identity.sh --identity wordpress-dev --bucket wordpress-assets --bucket wordpress-backup\n'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity|-i) [[ $# -ge 2 ]] || { printf '[ERROR] --identity requires a value.\n' >&2; exit 1; }; identity_name="$2"; shift 2 ;;
        --bucket|-b) [[ $# -ge 2 ]] || { printf '[ERROR] --bucket requires a value.\n' >&2; exit 1; }; bucket_names+=("$2"); shift 2 ;;
        --endpoint|-e) [[ $# -ge 2 ]] || { printf '[ERROR] --endpoint requires a value.\n' >&2; exit 1; }; s3_endpoint="$2"; shift 2 ;;
        --confirm) [[ $# -ge 2 ]] || { printf '[ERROR] --confirm requires a value.\n' >&2; exit 1; }; confirm_delete="$2"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        --list-buckets) list_buckets=1; shift ;;
        --identity-only) identity_only=1; shift ;;
        --all) delete_all=1; shift ;;
        --ignore-missing) ignore_missing=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) printf '[ERROR] Unknown argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -z "${identity_name}" || ( ${#bucket_names[@]} -eq 0 && ${list_buckets} -eq 0 && ${identity_only} -eq 0 && ${delete_all} -eq 0 ) ]]; then
    printf '[ERROR] --identity and a bucket selection are required. Use --bucket, --all, --list-buckets, or --identity-only.\n' >&2
    usage >&2
    exit 1
fi
if (( delete_all && ${#bucket_names[@]} > 0 )); then
    printf '[ERROR] Do not combine --all with --bucket.\n' >&2
    exit 1
fi
if (( delete_all && identity_only )); then
    printf '[ERROR] Do not combine --all with --identity-only.\n' >&2
    exit 1
fi
[[ -f "${ENV_FILE}" ]] || { printf '[ERROR] Missing %s.\n' "${ENV_FILE}" >&2; exit 1; }
[[ -f "${IDENTITIES_FILE}" ]] || { printf '[ERROR] Missing %s.\n' "${IDENTITIES_FILE}" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { printf '[ERROR] AWS CLI is required.\n' >&2; exit 1; }

# shellcheck disable=SC1090
source "${ENV_FILE}"
identity_record="$(awk -F'|' -v name="${identity_name}" '$1 == name { print; exit }' "${IDENTITIES_FILE}")"
[[ -n "${identity_record}" ]] || { printf '[ERROR] Identity does not exist: %s\n' "${identity_name}" >&2; exit 1; }
IFS='|' read -r _ access_key secret_key _ <<< "${identity_record}"
[[ -n "${access_key}" && -n "${secret_key}" ]] || { printf '[ERROR] Identity record is incomplete.\n' >&2; exit 1; }
export AWS_ACCESS_KEY_ID="${access_key}" AWS_SECRET_ACCESS_KEY="${secret_key}" AWS_DEFAULT_REGION="${SEAWEEDFS_S3_REGION:-us-east-1}"

if (( list_buckets )); then
    printf 'Buckets accessible by identity: %s\n' "${identity_name}"
    aws --endpoint-url "${s3_endpoint}" s3api list-buckets --query 'Buckets[].Name' --output text
    exit 0
fi

if (( delete_all )); then
    mapfile -t bucket_names < <(aws --endpoint-url "${s3_endpoint}" s3api list-buckets --query 'Buckets[].Name' --output text | tr '\t' '\n' | sed '/^None$/d;/^$/d')
    if [[ ${#bucket_names[@]} -eq 0 ]]; then
        printf '[ERROR] No accessible buckets were found. The identity will not be removed.\n' >&2
        exit 1
    fi
fi

if (( identity_only )); then
    printf 'Identity to revoke: %s\nBuckets will be preserved.\n' "${identity_name}"
else
    printf 'Identity to remove: %s\nBuckets to delete:\n' "${identity_name}"
    for bucket_name in "${bucket_names[@]}"; do printf '  - %s\n' "${bucket_name}"; done
fi
printf 'Endpoint: %s\n' "${s3_endpoint}"

for bucket_name in "${bucket_names[@]}"; do
    if ! aws --endpoint-url "${s3_endpoint}" s3api head-bucket --bucket "${bucket_name}" >/dev/null 2>&1; then
        if (( ignore_missing )); then printf '[WARN] Bucket is missing; skipping: %s\n' "${bucket_name}";
        else printf '[ERROR] Bucket is missing or inaccessible: %s\n' "${bucket_name}" >&2; printf 'Use --ignore-missing only when intentional.\n' >&2; exit 1; fi
    fi
done

if (( dry_run )); then printf 'DRY RUN: no buckets or identity were changed.\n'; exit 0; fi

if (( identity_only )); then
    expected="REVOKE ${identity_name}"
else
    expected="DELETE ${identity_name}"
fi
if [[ "${confirm_delete}" != "${expected}" ]]; then
    printf '\nThis operation is irreversible. Type exactly: %s\n' "${expected}"
    read -r -p '> ' confirm_delete
fi
[[ "${confirm_delete}" == "${expected}" ]] || { printf '[ERROR] Confirmation did not match. Nothing was deleted.\n' >&2; exit 1; }

if (( identity_only == 0 )); then
    for bucket_name in "${bucket_names[@]}"; do
        aws --endpoint-url "${s3_endpoint}" s3 rb "s3://${bucket_name}" --force || { printf '[ERROR] Failed to delete bucket: %s. Identity was preserved.\n' "${bucket_name}" >&2; exit 1; }
        printf '[INFO] Deleted bucket: %s\n' "${bucket_name}"
    done
fi

backup_file="${IDENTITIES_FILE}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "${IDENTITIES_FILE}" "${backup_file}"
tmp_file="$(mktemp "${IDENTITIES_FILE}.tmp.XXXXXX")"
trap 'rm -f -- "${tmp_file}"' EXIT
awk -F'|' -v name="${identity_name}" '$1 != name' "${IDENTITIES_FILE}" > "${tmp_file}"
mv -- "${tmp_file}" "${IDENTITIES_FILE}"
trap - EXIT

printf '[INFO] Removed identity: %s\n[INFO] Backup: %s\n' "${identity_name}" "${backup_file}"
"${SCRIPT_DIR}/install-seaweedfs.sh"
docker restart mas-storage-seaweedfs >/dev/null
printf '[INFO] Cleanup completed successfully.\n'
