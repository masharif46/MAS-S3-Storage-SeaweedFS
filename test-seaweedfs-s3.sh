#!/usr/bin/env bash
set -euo pipefail

BACKEND="${OBJECT_STORAGE_BACKEND:-seaweedfs}"

case "$BACKEND" in
  seaweedfs)
    ENDPOINT="${SEAWEEDFS_S3_ENDPOINT:?SEAWEEDFS_S3_ENDPOINT is required}"
    REGION="${SEAWEEDFS_S3_REGION:-us-east-1}"
    ACCESS_KEY="${SEAWEEDFS_ACCESS_KEY:?SEAWEEDFS_ACCESS_KEY is required}"
    SECRET_KEY="${SEAWEEDFS_SECRET_KEY:?SEAWEEDFS_SECRET_KEY is required}"
    ;;

  linode)
    ENDPOINT="${LINODE_S3_ENDPOINT:?LINODE_S3_ENDPOINT is required}"
    REGION="${LINODE_S3_REGION:?LINODE_S3_REGION is required}"
    ACCESS_KEY="${LINODE_ACCESS_KEY:?LINODE_ACCESS_KEY is required}"
    SECRET_KEY="${LINODE_SECRET_KEY:?LINODE_SECRET_KEY is required}"
    ;;

  *)
    echo "ERROR: Unsupported OBJECT_STORAGE_BACKEND: $BACKEND"
    exit 1
    ;;
esac

command -v aws >/dev/null 2>&1 || {
  echo "ERROR: aws CLI is not installed"
  exit 1
}

export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
export AWS_DEFAULT_REGION="$REGION"
export AWS_EC2_METADATA_DISABLED=true

BUCKET="object-storage-test-$(date +%s)-$$"
LOCAL_FILE="$(mktemp)"
DOWNLOADED_FILE="$(mktemp)"

cleanup() {
  echo
  echo "Cleaning up..."

  aws \
    --endpoint-url "$ENDPOINT" \
    s3 rm "s3://$BUCKET/" \
    --recursive >/dev/null 2>&1 || true

  aws \
    --endpoint-url "$ENDPOINT" \
    s3api delete-bucket \
    --bucket "$BUCKET" >/dev/null 2>&1 || true

  rm -f "$LOCAL_FILE" "$DOWNLOADED_FILE"
}

trap cleanup EXIT

echo "Backend : $BACKEND"
echo "Endpoint: $ENDPOINT"
echo "Region  : $REGION"
echo

echo "=== 1. Testing S3 connectivity ==="
aws \
  --endpoint-url "$ENDPOINT" \
  s3api list-buckets >/dev/null

echo "OK: S3 endpoint reachable"

echo
echo "=== 2. Creating bucket: $BUCKET ==="
aws \
  --endpoint-url "$ENDPOINT" \
  s3api create-bucket \
  --bucket "$BUCKET" >/dev/null

echo "OK: bucket created"

echo
echo "=== 3. Creating test object ==="
{
  echo "Object storage test"
  echo "backend=$BACKEND"
  echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "random=$RANDOM-$RANDOM"
} > "$LOCAL_FILE"

echo
echo "=== 4. Uploading object ==="
aws \
  --endpoint-url "$ENDPOINT" \
  s3 cp "$LOCAL_FILE" "s3://$BUCKET/test.txt"

echo "OK: upload succeeded"

echo
echo "=== 5. Listing bucket ==="
aws \
  --endpoint-url "$ENDPOINT" \
  s3 ls "s3://$BUCKET/"

echo
echo "=== 6. Reading object metadata ==="
aws \
  --endpoint-url "$ENDPOINT" \
  s3api head-object \
  --bucket "$BUCKET" \
  --key test.txt

echo
echo "=== 7. Downloading object ==="
aws \
  --endpoint-url "$ENDPOINT" \
  s3 cp "s3://$BUCKET/test.txt" "$DOWNLOADED_FILE"

echo
echo "=== 8. Verifying downloaded data ==="
if cmp -s "$LOCAL_FILE" "$DOWNLOADED_FILE"; then
  echo "OK: uploaded and downloaded files are identical"
else
  echo "ERROR: downloaded file differs from uploaded file"
  exit 1
fi

echo
echo "========================================"
echo "ALL OBJECT STORAGE TESTS PASSED"
echo "========================================"