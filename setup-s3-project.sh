#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly IDENTITY_SCRIPT="${SCRIPT_DIR}/add-s3-identity.sh"

usage() {
    printf 'Usage: ./setup-s3-project.sh [--project NAME] [--bucket NAME]\n'
    printf '\nPrompts for missing values, ensures the bucket exists, then creates or updates the project identity.\n'
}

project_name=''
bucket_name=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) [[ $# -ge 2 ]] || { printf '[ERROR] --project requires a value.\n' >&2; exit 2; }; project_name="$2"; shift 2 ;;
        --bucket) [[ $# -ge 2 ]] || { printf '[ERROR] --bucket requires a value.\n' >&2; exit 2; }; bucket_name="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) printf '[ERROR] Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "${project_name}" ]]; then
    read -r -p 'Project name: ' project_name
fi
if [[ -z "${bucket_name}" ]]; then
    read -r -p 'Bucket name: ' bucket_name
fi

[[ "${project_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || {
    printf '[ERROR] Project name must be 1-63 characters using letters, numbers, dot, underscore, or hyphen.\n' >&2
    exit 2
}
[[ "${bucket_name}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || {
    printf '[ERROR] Bucket name must be 3-63 lowercase letters, numbers, dots, or hyphens, and start and end with a letter or number.\n' >&2
    exit 2
}
[[ -x "${IDENTITY_SCRIPT}" ]] || { printf '[ERROR] Identity script is missing or not executable: %s\n' "${IDENTITY_SCRIPT}" >&2; exit 1; }

printf '\nProject: %s\nBucket:  s3://%s\n\n' "${project_name}" "${bucket_name}"
printf '[INFO] Checking or creating the bucket with administrator credentials.\n'
printf '[INFO] Creating the project identity or adding this bucket to the existing identity.\n'

if [[ "${EUID}" -eq 0 ]]; then
    exec "${IDENTITY_SCRIPT}" "${project_name}" --bucket "${bucket_name}"
else
    exec sudo "${IDENTITY_SCRIPT}" "${project_name}" --bucket "${bucket_name}"
fi
