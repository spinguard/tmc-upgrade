#!/usr/bin/env bash
#
# diff-snapshots.sh <kube-context> [output-root]
#
# Diffs the before/after snapshots for one cluster captured by snapshot-cluster.sh.
# output-root defaults to ./snapshots. With no context argument, lists what's
# available.
#
# See README.md section 4 for how to read the result.

set -uo pipefail

ROOT="${2:-snapshots}"
CTX="${1:-}"

if [ -z "$CTX" ]; then
  echo "usage: $(basename "$0") <kube-context> [output-root]" >&2
  echo "available snapshots under '${ROOT}':" >&2
  ls -1 "$ROOT" 2>/dev/null | sed 's/^/  /' >&2 || echo "  (none)" >&2
  exit 2
fi

BEFORE="${ROOT}/${CTX}/before"
AFTER="${ROOT}/${CTX}/after"

for d in "$BEFORE" "$AFTER"; do
  [ -d "$d" ] || { echo "error: missing snapshot dir '$d'" >&2; exit 1; }
done

echo "=== diff ${BEFORE} -> ${AFTER} ==="
# Exit 0 (no diff) or 1 (differences); anything else is a real error.
diff -ru "$BEFORE" "$AFTER"
rc=$?
[ "$rc" -le 1 ] && exit 0 || exit "$rc"
