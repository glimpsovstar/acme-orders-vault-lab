#!/bin/bash
# Checks the app bundle holds only expected files, even with secret-looking
# files planted in the app folder. Builds the zip through the mocked terraform test.
# Usage: bash tests/archive_allowlist.sh
#   The app folder is APP_SOURCE_DIR, else TF_VAR_app_source_dir, else ../../app.
#   A relative path is taken from the terraform folder, the same as app_source_dir.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tf=$(cd "$here/.." && pwd)
src=${APP_SOURCE_DIR:-${TF_VAR_app_source_dir:-../../app}}
case "$src" in /*) ;; *) src="$tf/$src";; esac
app=$(cd "$src" && pwd)
zip="$tf/.build/app.zip"

plants=("$app/.env" "$app/.env.local" "$app/.lab.env" "$app/acme/.env" "$app/acme/stray.pyc")
for f in "${plants[@]}"; do
  if [ -e "$f" ]; then
    echo "archive_allowlist: $f already exists, refusing to touch it" >&2
    exit 1
  fi
done
cleanup() { rm -f "${plants[@]}"; }
trap cleanup EXIT
for f in "${plants[@]}"; do echo "PLANTED=dummy" >"$f"; done

rm -f "$zip"
# Assertion results do not matter here, only the zip the run builds.
terraform -chdir="$tf" test -no-color -var "app_source_dir=$app" >/dev/null 2>&1 || true
if [ ! -f "$zip" ]; then
  echo "FAIL: terraform test did not build $zip" >&2
  exit 1
fi

allow='^(\.containerignore|Containerfile|LICENSE|README\.md|compose\.yaml|requirements\.txt|rotate|seed\.sql|acme/[A-Za-z0-9_]+\.py|acme/static/[A-Za-z0-9_.]+\.(css|js)|acme/static/fonts/[A-Za-z0-9_.]+\.(woff2|txt)|acme/templates/[A-Za-z0-9_]+\.html)$'
bad=$(python3 -I -c 'import sys, zipfile; print("\n".join(n for n in zipfile.ZipFile(sys.argv[1]).namelist() if not n.endswith("/")))' "$zip" | grep -Ev "$allow" || true)
if [ -n "$bad" ]; then
  echo "FAIL: unexpected files in the app bundle:" >&2
  echo "$bad" >&2
  exit 1
fi
echo "archive_allowlist.sh: bundle holds only allowed files"
