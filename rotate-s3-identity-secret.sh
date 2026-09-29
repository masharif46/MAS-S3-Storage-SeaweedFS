#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly IDENTITIES_FILE="${SCRIPT_DIR}/.seaweedfs/identities.conf"

identity_name="${1:-}"
confirmation=""
usage() { printf 'Usage: sudo ./rotate-s3-identity-secret.sh IDENTITY [--confirm "ROTATE IDENTITY"]\n'; printf 'Example: sudo ./rotate-s3-identity-secret.sh laravel-dev\n'; }
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then usage; exit 0; fi
shift || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --confirm) [[ $# -ge 2 ]] || { printf '[ERROR] --confirm requires a value.\n' >&2; exit 1; }; confirmation="$2"; shift 2 ;;
        *) printf '[ERROR] Unknown argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ "${identity_name}" =~ ^[A-Za-z0-9._-]+$ ]] || { usage >&2; exit 1; }
[[ -f "${ENV_FILE}" ]] || { printf '[ERROR] Missing %s.\n' "${ENV_FILE}" >&2; exit 1; }
[[ -f "${IDENTITIES_FILE}" ]] || { printf '[ERROR] Missing %s.\n' "${IDENTITIES_FILE}" >&2; exit 1; }
record="$(awk -F'|' -v name="${identity_name}" '$1 == name { print; exit }' "${IDENTITIES_FILE}")"
[[ -n "${record}" ]] || { printf '[ERROR] Identity does not exist: %s\n' "${identity_name}" >&2; exit 1; }
IFS='|' read -r name access_key old_secret actions <<< "${record}"
[[ "${actions}" != *Admin* ]] || { printf '[ERROR] Refusing to rotate an Admin identity with this script.\n' >&2; exit 1; }

expected="ROTATE ${identity_name}"
if [[ "${confirmation}" != "${expected}" ]]; then
    printf 'This invalidates the current secret key. Buckets and access key remain unchanged.\nType exactly: %s\n' "${expected}"
    read -r -p '> ' confirmation
fi
[[ "${confirmation}" == "${expected}" ]] || { printf '[ERROR] Confirmation did not match. Nothing was changed.\n' >&2; exit 1; }

if command -v openssl >/dev/null 2>&1; then new_secret="$(openssl rand -hex 32)"; else new_secret="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"; fi
backup_file="${IDENTITIES_FILE}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "${IDENTITIES_FILE}" "${backup_file}"
tmp_file="$(mktemp "${IDENTITIES_FILE}.tmp.XXXXXX")"
trap 'rm -f -- "${tmp_file}"' EXIT
awk -F'|' -v name="${identity_name}" -v replacement="${name}|${access_key}|${new_secret}|${actions}" '$1 == name { print replacement; next } { print }' "${IDENTITIES_FILE}" >"${tmp_file}"
mv -- "${tmp_file}" "${IDENTITIES_FILE}"
trap - EXIT

"${SCRIPT_DIR}/install-seaweedfs.sh" >/dev/null
docker restart mas-storage-seaweedfs >/dev/null
printf 'Secret rotated successfully for: %s\nAccess key (unchanged): %s\nNew secret key:          %s\nIdentity backup:         %s\n\nUpdate the application secret immediately. The old secret is now invalid.\n' "${identity_name}" "${access_key}" "${new_secret}" "${backup_file}"
