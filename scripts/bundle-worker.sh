#!/bin/bash
# Rebuilds the sharing server bundle that the Mac app installs on the user's Cloudflare account.
# Run after any change in cloud/src or cloud/migrations.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/App/Resources/Worker"
cd "$ROOT/cloud"
npx wrangler deploy --dry-run --outdir "$OUT" >/dev/null
rm -f "$OUT/index.js.map" "$OUT/README.md"
cat migrations/*.sql > "$OUT/schema.sql"
echo "$OUT"
