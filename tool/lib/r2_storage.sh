#!/usr/bin/env bash
# Sourced R2 transport; caller loads release.env without tracing credentials.
s3_url() { echo "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${R2_BUCKET}/${R2_PREFIX}/$1"; }
s3_curl() {
  curl -sS --aws-sigv4 "aws:amz:auto:s3" --user "${R2_ACCESS_KEY_ID}:${R2_SECRET_ACCESS_KEY}" "$@"
}
