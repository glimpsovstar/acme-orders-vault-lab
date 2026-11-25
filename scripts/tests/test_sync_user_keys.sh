#!/bin/bash
# Offline test for sync-user-keys.sh. A fake aws CLI stands in for AWS.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../sync-user-keys.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

fake_secret="fake-secret-value-for-this-test"
mkdir -p "$work/bin"
cat >"$work/bin/aws" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$work/aws-argv"
if [ "\${FAKE_AWS_FAIL:-}" = 1 ]; then echo "boom" >&2; exit 254; fi
printf '{"access_key_id": "FAKEKEYIDFORTEST", "secret_access_key": "$fake_secret"}\n'
EOF
chmod +x "$work/bin/aws"
export PATH="$work/bin:$PATH"

# 1. Writes a 0600 file and prints nothing with the key in it.
PATH="$work/bin:$PATH" bash "$script" acme-orders-sync "$work/keys.json" >"$work/stdout" 2>"$work/stderr"
mode=$(stat -f '%Lp' "$work/keys.json" 2>/dev/null || stat -c '%a' "$work/keys.json")
[ "$mode" = 600 ] || fail "file mode is $mode, want 600"
grep -q "$fake_secret" "$work/keys.json" || fail "key not in the file"
if grep -q "$fake_secret" "$work/stdout" "$work/stderr"; then fail "secret printed"; fi
if grep -q FAKEKEYID "$work/stdout" "$work/stderr"; then fail "key ID printed"; fi
[ ! -s "$work/stdout" ] || fail "stdout not empty"
grep -q -- "--user-name acme-orders-sync" "$work/aws-argv" || fail "wrong user passed to aws"

# 2. Refuses to overwrite an existing file.
if bash "$script" acme-orders-sync "$work/keys.json" 2>/dev/null; then fail "overwrote an existing file"; fi

# 3. AWS failure leaves no file behind.
if FAKE_AWS_FAIL=1 bash "$script" acme-orders-sync "$work/k2.json" 2>/dev/null; then fail "AWS failure not reported"; fi
[ ! -e "$work/k2.json" ] || fail "file left after AWS failure"

# 4. Usage error without arguments.
if bash "$script" 2>/dev/null; then fail "ran without arguments"; fi

if [ "$fails" -gt 0 ]; then
  echo "test_sync_user_keys.sh: $fails failures" >&2
  exit 1
fi
echo "test_sync_user_keys.sh: 4 scenarios passed"
