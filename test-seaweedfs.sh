#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly IDENTITIES_FILE="${SCRIPT_DIR}/.seaweedfs/identities.conf"
readonly CONTAINER_NAME="mas-storage-seaweedfs"
readonly DATA_DIR="/opt/mas-storage-seaweedfs"
readonly S3_HOSTNAME="mas-storage-seaweedfs.com"
readonly ADMIN_HOSTNAME="admin.mas-storage-seaweedfs.com"

pass_count=0
fail_count=0
warn_count=0
strict_nginx=false

for argument in "$@"; do
    case "${argument}" in
        --strict-nginx) strict_nginx=true ;;
        --help|-h)
            printf 'Usage: sudo ./test-seaweedfs.sh [--strict-nginx]\n'
            printf '  --strict-nginx  Treat Nginx hostname failures as test failures.\n'
            exit 0
            ;;
        *) printf '[ERROR] Unknown option: %s\n' "${argument}" >&2; exit 2 ;;
    esac
done

pass() { printf '[PASS] %s\n' "$*"; pass_count=$((pass_count + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; fail_count=$((fail_count + 1)); }
warn() { printf '[WARN] %s\n' "$*"; warn_count=$((warn_count + 1)); }

check_command() {
    command -v "$1" >/dev/null 2>&1 && pass "Command available: $1" || fail "Command missing: $1"
}

http_status() {
    curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 10 "$1" 2>/dev/null || printf '000'
}

printf '\nSeaweedFS deployment test\n'
printf '%s\n' '========================='

check_command docker
check_command curl

if ! docker info >/dev/null 2>&1; then
    fail 'Docker daemon is unavailable'
else
    pass 'Docker daemon is available'
fi

if [[ ! -f "${ENV_FILE}" ]]; then
    fail "Configuration file missing: ${ENV_FILE}"
else
    pass 'Configuration file exists'
fi

if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    fail "Container does not exist: ${CONTAINER_NAME}"
else
    running="$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}")"
    restart_count="$(docker inspect -f '{{.RestartCount}}' "${CONTAINER_NAME}")"
    [[ "${running}" == true ]] && pass 'Container is running' || fail 'Container is not running'
    [[ "${restart_count}" == 0 ]] && pass 'Container has no restart loop' || warn "Container restart count: ${restart_count}"
fi

if [[ -d "${DATA_DIR}" ]]; then
    pass "Data directory exists: ${DATA_DIR}"
    if [[ -w "${DATA_DIR}" ]]; then pass 'Data directory is writable'; else fail 'Data directory is not writable'; fi
    printf '\nStorage capacity:\n'
    du -sh "${DATA_DIR}" 2>/dev/null || true
    df -h "${DATA_DIR}" 2>/dev/null || true
else
    fail "Data directory is missing: ${DATA_DIR}"
fi

s3_status="$(http_status http://127.0.0.1:28333)"
case "${s3_status}" in
    2*|3*|403) pass "S3 endpoint responds: HTTP ${s3_status}" ;;
    *) fail "S3 endpoint failed: HTTP ${s3_status}" ;;
esac

admin_status="$(http_status http://127.0.0.1:29333)"
case "${admin_status}" in
    2*|3*) pass "Admin endpoint responds: HTTP ${admin_status}" ;;
    *) fail "Admin endpoint failed: HTTP ${admin_status}" ;;
esac

for endpoint in "http://${S3_HOSTNAME}" "http://${ADMIN_HOSTNAME}"; do
    status="$(http_status "${endpoint}")"
    case "${status}" in
        2*|3*|403) pass "Nginx endpoint responds: ${endpoint} HTTP ${status}" ;;
        *)
            if [[ "${strict_nginx}" == true ]]; then
                fail "Nginx endpoint failed: ${endpoint} HTTP ${status}"
            else
                warn "Nginx endpoint unavailable: ${endpoint} HTTP ${status}"
            fi
            ;;
    esac
done

if command -v aws >/dev/null 2>&1 && [[ -f "${IDENTITIES_FILE}" ]]; then
    identity_line="$(/usr/bin/grep -E '^default[|]' "${IDENTITIES_FILE}" || true)"
    if [[ -n "${identity_line}" ]]; then
        IFS='|' read -r _ access_key secret_key _ <<<"${identity_line}"
        export AWS_ACCESS_KEY_ID="${access_key}"
        export AWS_SECRET_ACCESS_KEY="${secret_key}"
        # AWS CLI v2 may have no default region under sudo. SeaweedFS accepts
        # the standard S3 default region used throughout this deployment.
        export AWS_DEFAULT_REGION='us-east-1'
        if aws --endpoint-url http://127.0.0.1:28333 s3 ls >/dev/null 2>&1; then
            pass 'Authenticated S3 API request succeeded'
        else
            fail 'Authenticated S3 API request failed'
        fi
    else
        warn 'Default S3 identity is not configured; skipping authenticated test'
    fi
else
    warn 'AWS CLI or identity file unavailable; skipping authenticated S3 test'
fi

printf '\nTest summary: %s passed, %s failed, %s warnings\n' "${pass_count}" "${fail_count}" "${warn_count}"
[[ "${fail_count}" -eq 0 ]]
