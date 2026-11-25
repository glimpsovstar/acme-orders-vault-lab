#!/bin/bash
# Create an access key for the Vault secrets sync IAM user and write it to a
# new 0600 JSON file. The key is never printed, and never in Terraform state.
#
# Usage: scripts/sync-user-keys.sh <iam user name> <output file>
#   The user name is the sync_principal Terraform output (sync_auth = iam_user).
#   The file holds {"access_key_id": ..., "secret_access_key": ...}, ready for
#   vault write sys/sync/destinations/aws-sm/<name> @<output file> region=...
#   Delete the file once Vault has the key.
set -euo pipefail

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: $0 <iam user name> <output file>" >&2
  exit 2
fi
user=$1
out=$2

if ! command -v aws >/dev/null 2>&1; then
  echo "sync-user-keys: the aws CLI is not installed" >&2
  exit 1
fi
if [ -e "$out" ]; then
  echo "sync-user-keys: $out already exists, not overwriting it" >&2
  exit 1
fi

umask 077
set -o noclobber
if ! aws iam create-access-key --user-name "$user" --output json \
  --query '{access_key_id: AccessKey.AccessKeyId, secret_access_key: AccessKey.SecretAccessKey}' \
  >"$out"; then
  rm -f "$out"
  echo "sync-user-keys: aws iam create-access-key failed, no file written" >&2
  exit 1
fi
chmod 0600 "$out"
echo "sync-user-keys: wrote a new access key for $user to $out (mode 0600)" >&2
