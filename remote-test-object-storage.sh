#!/usr/bin/env bash
set -Eeuo pipefail

endpoint="${S3_ENDPOINT:-http://mas-storage-seaweedfs.com}"
bucket="${S3_BUCKET:-}"
access_key="${AWS_ACCESS_KEY_ID:-}"
secret_key="${AWS_SECRET_ACCESS_KEY:-}"
region="${AWS_DEFAULT_REGION:-us-east-1}"
size_mb=1
keep_object=0

usage() {
    printf 'Usage: %s --bucket NAME [--endpoint URL] [--access-key KEY] [--secret-key SECRET] [--size-mb N] [--keep-object]\n' "$(basename "$0")"
    printf '\nEnvironment variables are also supported: S3_ENDPOINT, S3_BUCKET, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION.\n'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --endpoint|-e) [[ $# -ge 2 ]] || { printf '[ERROR] --endpoint requires a value.\n' >&2; exit 1; }; endpoint="$2"; shift 2 ;;
        --bucket|-b) [[ $# -ge 2 ]] || { printf '[ERROR] --bucket requires a value.\n' >&2; exit 1; }; bucket="$2"; shift 2 ;;
        --access-key) [[ $# -ge 2 ]] || { printf '[ERROR] --access-key requires a value.\n' >&2; exit 1; }; access_key="$2"; shift 2 ;;
        --secret-key) [[ $# -ge 2 ]] || { printf '[ERROR] --secret-key requires a value.\n' >&2; exit 1; }; secret_key="$2"; shift 2 ;;
        --region) [[ $# -ge 2 ]] || { printf '[ERROR] --region requires a value.\n' >&2; exit 1; }; region="$2"; shift 2 ;;
        --size-mb) [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { printf '[ERROR] --size-mb must be a positive integer.\n' >&2; exit 1; }; size_mb="$2"; shift 2 ;;
        --keep-object) keep_object=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) printf '[ERROR] Unknown argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ -n "${bucket}" ]] || { printf '[ERROR] A bucket is required.\n' >&2; usage >&2; exit 1; }
[[ -n "${access_key}" ]] || { printf '[ERROR] AWS_ACCESS_KEY_ID or --access-key is required.\n' >&2; exit 1; }
[[ -n "${secret_key}" ]] || { printf '[ERROR] AWS_SECRET_ACCESS_KEY or --secret-key is required.\n' >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { printf '[ERROR] AWS CLI is required on the remote computer.\n' >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { printf '[ERROR] sha256sum is required.\n' >&2; exit 1; }

export AWS_ACCESS_KEY_ID="${access_key}" AWS_SECRET_ACCESS_KEY="${secret_key}" AWS_DEFAULT_REGION="${region}"
work_dir="$(mktemp -d)"
object_key="remote-test/$(hostname)-$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}.bin"
source_file="${work_dir}/source.bin"
download_file="${work_dir}/download.bin"
cleanup() {
    if (( keep_object == 0 )); then
        aws --endpoint-url "${endpoint}" s3api delete-object --bucket "${bucket}" --key "${object_key}" >/dev/null 2>&1 || true
    fi
    rm -rf -- "${work_dir}"
}
trap cleanup EXIT

printf 'Remote object-storage test\n==========================\n'
printf 'Endpoint: %s\nBucket:   %s\nObject:   %s\nSize:     %s MiB\n\n' "${endpoint}" "${bucket}" "${object_key}" "${size_mb}"

printf '[1/5] Checking bucket access...\n'
aws --endpoint-url "${endpoint}" s3api head-bucket --bucket "${bucket}" >/dev/null

printf '[2/5] Creating test file...\n'
dd if=/dev/urandom of="${source_file}" bs=1M count="${size_mb}" status=none
source_hash="$(sha256sum "${source_file}" | awk '{print $1}')"

printf '[3/5] Uploading object...\n'
aws --endpoint-url "${endpoint}" s3api put-object --bucket "${bucket}" --key "${object_key}" --body "${source_file}" >/dev/null

printf '[4/5] Downloading object...\n'
aws --endpoint-url "${endpoint}" s3api get-object --bucket "${bucket}" --key "${object_key}" "${download_file}" >/dev/null
download_hash="$(sha256sum "${download_file}" | awk '{print $1}')"

printf '[5/5] Verifying integrity...\n'
if [[ "${source_hash}" != "${download_hash}" ]]; then
    printf '[ERROR] Checksum mismatch.\nSource:   %s\nDownload: %s\n' "${source_hash}" "${download_hash}" >&2
    exit 1
fi

if (( keep_object )); then
    printf '\nPASS: upload/download/checksum succeeded. Test object was kept.\n'
else
    printf '\nPASS: upload/download/checksum succeeded. Test object will be removed.\n'
fi
