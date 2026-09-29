#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly IDENTITIES_FILE="${SCRIPT_DIR}/.seaweedfs/identities.conf"

usage() {
    printf 'Usage: sudo ./add-s3-identity.sh PROJECT --bucket NAME [--bucket NAME ...] [--no-apply]\n'
    printf 'Creates a project identity or adds bucket access while preserving existing credentials.\n'
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then usage; exit 0; fi

project_name="${1:-}"
shift || true
declare -a bucket_names=()
apply_config=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bucket|-b) [[ $# -ge 2 ]] || { printf '[ERROR] --bucket requires a value.\n' >&2; exit 2; }; bucket_names+=("$2"); shift 2 ;;
        --no-apply) apply_config=false; shift ;;
        --help|-h) usage; exit 0 ;;
        *) printf '[ERROR] Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "${project_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || { printf '[ERROR] Project name must be 1-63 valid characters.\n' >&2; exit 2; }
[[ ${#bucket_names[@]} -gt 0 ]] || { printf '[ERROR] Specify at least one bucket with --bucket.\n' >&2; exit 2; }

declare -A unique_buckets=()
for bucket_name in "${bucket_names[@]}"; do
    [[ "${bucket_name}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || { printf '[ERROR] Invalid bucket name: %s\n' "${bucket_name}" >&2; exit 2; }
    unique_buckets["${bucket_name}"]=1
done
bucket_names=("${!unique_buckets[@]}")

[[ -f "${ENV_FILE}" && -f "${IDENTITIES_FILE}" ]] || { printf '[ERROR] Run install-seaweedfs.sh first.\n' >&2; exit 1; }
# shellcheck disable=SC1090
source "${ENV_FILE}"
[[ -n "${S3_ACCESS_KEY:-}" && -n "${S3_SECRET_KEY:-}" ]] || { printf '[ERROR] Administrator credentials are missing from .env.\n' >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { printf '[ERROR] AWS CLI is required to validate buckets.\n' >&2; exit 1; }

record="$(awk -F'|' -v project="${project_name}" '$1 == project { print; exit }' "${IDENTITIES_FILE}")"
if [[ -n "${record}" ]]; then
    IFS='|' read -r _ access_key secret_key actions <<<"${record}"
    [[ "${actions}" != *Admin* ]] || { printf '[ERROR] Refusing to use Admin identity as a project identity: %s\n' "${project_name}" >&2; exit 1; }
fi

admin_endpoint="http://127.0.0.1:${S3_PORT:-28333}"
for bucket_name in "${bucket_names[@]}"; do
    if ! bucket_list="$(AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY}" AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" AWS_DEFAULT_REGION=us-east-1 aws --endpoint-url "${admin_endpoint}" s3api list-buckets --query "Buckets[?Name=='${bucket_name}'].Name | [0]" --output text 2>&1)"; then
        printf '[ERROR] Could not verify bucket %s with the administrator identity.\n' "${bucket_name}" >&2
        exit 1
    fi
    if [[ "${bucket_list}" == "${bucket_name}" ]]; then
        printf '[INFO] Bucket already exists: s3://%s\n' "${bucket_name}"
    else
        printf '[INFO] Creating bucket: s3://%s\n' "${bucket_name}"
        AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY}" AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" AWS_DEFAULT_REGION=us-east-1 aws --endpoint-url "${admin_endpoint}" s3 mb "s3://${bucket_name}"
    fi
done

created=false
declare -a newly_granted=()
if [[ -n "${record}" ]]; then
    printf '[INFO] Project identity already exists: %s; existing credentials will be preserved.\n' "${project_name}"
else
    if command -v openssl >/dev/null 2>&1; then secret_key="$(openssl rand -hex 32)"; else secret_key="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"; fi
    access_key="mas-${project_name}"
    actions=''
    created=true
fi

for bucket_name in "${bucket_names[@]}"; do
    bucket_changed=false
    for permission in "Read:${bucket_name}" "List:${bucket_name}" "Tagging:${bucket_name}" "Write:${bucket_name}"; do
        case ",${actions}," in
            *",${permission},"*) ;;
            *) [[ -z "${actions}" ]] || actions+=','; actions+="${permission}"; bucket_changed=true ;;
        esac
    done
    [[ "${bucket_changed}" == true ]] && newly_granted+=("${bucket_name}")
done

if [[ "${created}" == false && ${#newly_granted[@]} -eq 0 ]]; then
    printf '[INFO] Identity already has access to every requested bucket. No changes needed.\n'
    exit 0
fi
for bucket_name in "${newly_granted[@]}"; do printf '[INFO] Adding bucket permission: %s\n' "${bucket_name}"; done

umask 077
backup_file="${IDENTITIES_FILE}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "${IDENTITIES_FILE}" "${backup_file}"
tmp_file="$(mktemp "${IDENTITIES_FILE}.tmp.XXXXXX")"
trap 'rm -f -- "${tmp_file}"' EXIT
if [[ "${created}" == true ]]; then
    cp -- "${IDENTITIES_FILE}" "${tmp_file}"
    printf '%s|%s|%s|%s\n' "${project_name}" "${access_key}" "${secret_key}" "${actions}" >>"${tmp_file}"
else
    awk -F'|' -v project="${project_name}" -v replacement="${project_name}|${access_key}|${secret_key}|${actions}" '$1 == project { print replacement; next } { print }' "${IDENTITIES_FILE}" >"${tmp_file}"
fi
chmod 600 "${tmp_file}"
mv -- "${tmp_file}" "${IDENTITIES_FILE}"
trap - EXIT

if [[ "${created}" == true ]]; then
    printf '\nProject identity created. Save these credentials securely:\nAccess key: %s\nSecret key: %s\n' "${access_key}" "${secret_key}"
fi

if [[ "${apply_config}" == true ]]; then
    printf '[INFO] Applying identity configuration.\n'
    if ! "${SCRIPT_DIR}/install-seaweedfs.sh" --skip-pull; then
        printf '[ERROR] Registry updated, but activation failed. Run sudo ./install-seaweedfs.sh.\n' >&2
        exit 1
    fi
else
    printf '[INFO] Changes saved but not applied (--no-apply).\n'
fi

if [[ "${created}" == false ]]; then
    printf '\nExisting project credentials were preserved.\n'
fi
printf 'Completed: %s now has access to the requested bucket(s).\n' "${project_name}"
